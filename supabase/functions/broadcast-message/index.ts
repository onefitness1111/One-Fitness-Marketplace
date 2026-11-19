// One message to many clients, each in their own chat with the sender.
//
// The owner reaches every client. A coach reaches only their own clients.
// Channels are app chat, app chat plus a text, or email alone.
// A text uses the same Twilio number and the same opt-out checks as a
// normal chat text. It is not sent before 8:00am or from 9:00pm Pacific.
// Saving the chat message opens the usual 6-hour reply window.
// Email does not land in the chat thread.
//
// Signed-in staff call this. It does not use the cron secret.
// Deploy with the login check left on:
//   supabase functions deploy broadcast-message
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendEmailOrThrow } from "../_shared/sendEmail.ts";
import { sendPush } from "../_shared/sendPush.ts";
import {
  CORS_HEADERS,
  clip,
  enforceRateLimit,
  json,
  requireStaff,
} from "../_shared/messagingGuard.ts";
import { broadcastChannel, smsQuietHours } from "../_shared/broadcastRules.mjs";
import { publicCoachName } from "../_shared/coachName.ts";

const BATCH = 20;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const body = await req.json();
    const channel = broadcastChannel(body.channel);
    if (!channel) throw new Error("Pick app chat, app chat and text, or email.");
    const text = clip(body.text, channel === "email" ? 8000 : 1000, "Message");
    const subject = channel === "email"
      ? clip(body.subject, 200, "Subject")
      : String(body.subject ?? "").trim();
    const all = body.all === true;
    const requested = Array.isArray(body.clientIds) ? body.clientIds.map((id: unknown) => String(id)) : [];
    if (!all && requested.length === 0) throw new Error("Choose who should get this.");

    const { admin, userId, role } = await requireStaff(req);
    const { data: allowedRows, error: allowedErr } = await admin.rpc("broadcast_allowed_clients", { p_sender: userId });
    if (allowedErr) throw new Error("Couldn't check who you can message.");
    const allowed = new Set((allowedRows ?? []).map((row: { client_id: string }) => row.client_id));

    let ids: string[];
    const refused: string[] = [];
    if (all) {
      ids = [...allowed];
    } else {
      ids = [];
      for (const id of requested) {
        if (allowed.has(id)) ids.push(id);
        else if (id.trim()) refused.push(id);
      }
    }

    const people = await loadPeople(admin, ids);
    const quiet = smsQuietHours(new Date());
    const label = await senderLabel(admin, userId, role);

    const result = {
      ok: true,
      channel,
      app: { sent: 0, failed: 0 },
      sms: { sent: 0, skipped: 0, failed: 0, skippedNoPhone: 0, skippedOptOut: 0, skippedQuietHours: 0 },
      email: { sent: 0, skipped: 0, failed: 0, skippedNoEmail: 0 },
      refused: refused.length,
      rateLimited: 0,
    };

    let budget = await remainingBudget(admin, userId);
    for (let i = 0; i < people.length; i += BATCH) {
      const chunk = people.slice(i, i + BATCH);
      for (const person of chunk) {
        if (budget <= 0) {
          result.rateLimited += 1;
          if (channel === "email") result.email.failed += 1;
          else result.app.failed += 1;
          continue;
        }
        try {
          await enforceRateLimit(admin, userId, channel === "email" ? "email" : "broadcast");
          budget -= 1;
        } catch {
          budget = 0;
          result.rateLimited += 1;
          if (channel === "email") result.email.failed += 1;
          else result.app.failed += 1;
          continue;
        }

        if (channel === "email") {
          if (!person.email) {
            result.email.skipped += 1;
            result.email.skippedNoEmail += 1;
            continue;
          }
          try {
            await sendEmailOrThrow(person.email, subject, `${label}: ${text}`);
            result.email.sent += 1;
          } catch {
            result.email.failed += 1;
          }
          continue;
        }

        let includeSms = false;
        if (channel === "app_sms") {
          if (!person.phone) {
            result.sms.skipped += 1;
            result.sms.skippedNoPhone += 1;
          } else if (!person.smsOptIn || person.smsOptedOut) {
            result.sms.skipped += 1;
            result.sms.skippedOptOut += 1;
          } else if (quiet) {
            result.sms.skipped += 1;
            result.sms.skippedQuietHours += 1;
          } else {
            includeSms = true;
          }
        }

        const { error } = await admin.from("messages").insert({
          client_id: person.id,
          trainer_id: userId,
          sender_id: userId,
          who: "trainer",
          body: text,
          channel: includeSms ? "inapp,sms" : "inapp",
          read_by_coach: true,
        });
        if (error) {
          result.app.failed += 1;
          if (includeSms) result.sms.failed += 1;
          continue;
        }
        result.app.sent += 1;
        if (includeSms) result.sms.sent += 1;
        await notify(admin, person.id, label, text);
      }
    }

    return json(result);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("broadcast-message failed:", message);
    const status = message.includes("Wait a few minutes") ? 429 : 400;
    return json({ error: message }, status);
  }
});

// deno-lint-ignore no-explicit-any
async function remainingBudget(admin: any, senderId: string): Promise<number> {
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { count } = await admin
    .from("outbound_message_log")
    .select("id", { count: "exact", head: true })
    .eq("sender_id", senderId)
    .gte("created_at", since);
  return Math.max(0, 200 - (count ?? 0));
}

// deno-lint-ignore no-explicit-any
async function senderLabel(admin: any, userId: string, role: string): Promise<string> {
  if (role === "owner") return "ONE Fitness Marketplace";
  return publicCoachName(admin, userId);
}

// deno-lint-ignore no-explicit-any
async function loadPeople(admin: any, ids: string[]) {
  if (ids.length === 0) return [];
  const { data: profiles } = await admin
    .from("profiles")
    .select("id, email, phone, sms_opted_out, sms_consent_at")
    .in("id", ids);
  const { data: clients } = await admin
    .from("clients")
    .select("profile_id, sms_opt_in")
    .in("profile_id", ids);
  const opted = new Map((clients ?? []).map((row: { profile_id: string; sms_opt_in?: boolean }) => [row.profile_id, row.sms_opt_in === true]));
  return (profiles ?? []).map((row: { id: string; email?: string; phone?: string; sms_opted_out?: boolean; sms_consent_at?: string }) => ({
    id: row.id,
    email: String(row.email ?? "").trim(),
    phone: String(row.phone ?? "").trim(),
    smsOptedOut: row.sms_opted_out === true,
    smsOptIn: row.sms_consent_at != null || opted.get(row.id) === true,
  }));
}

// deno-lint-ignore no-explicit-any
async function notify(admin: any, profileId: string, from: string, text: string) {
  try {
    const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
    const tokens = (rows ?? []).map((row: { token?: string }) => String(row.token ?? "")).filter(Boolean);
    await sendPush(tokens, `New message from ${from}`, text, { kind: "broadcast" });
  } catch {
    // The chat row is already saved. A missed phone alert is not a failed send.
  }
}
