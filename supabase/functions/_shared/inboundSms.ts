// Inbound SMS from Twilio — STOP, START and HELP, plus a short automatic
// reply when a client is texting their coach.
//
// Twilio blocks further messages to a number that replies STOP at the
// carrier level, but it does not tell our database. Without this, the
// client stays `sms_opt_in = true`, the app keeps queueing texts that are
// silently dropped, and their own Notification Preferences screen shows SMS
// as on when it isn't. Carriers reviewing an A2P 10DLC campaign check that
// opt-out is honoured end to end, not just at the gateway.
//
// Deploy WITHOUT jwt verification — Twilio sends no JWT. Authentication is
// Twilio's request signature instead, which is verified below; without that
// check this endpoint would let anyone unsubscribe any number they liked.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { COACH_AUTO_REPLY, autoReplySuppressed } from "./autoReply.ts";
import { sendPush } from "./sendPush.ts";
import { sendSms } from "./sendSms.ts";
import { describeWebhookUrl, twilioSignatureMatches, webhookCandidates } from "./twilioWebhookUrl.ts";

const OPT_OUT = new Set(["STOP", "STOPALL", "CANCEL", "END", "QUIT", "UNSUBSCRIBE", "REVOKE", "OPTOUT"]);
const OPT_IN = new Set(["START", "YES", "UNSTOP", "JOIN", "OPTIN"]);
const HELP = new Set(["HELP", "INFO"]);

const CONSENT_TEXT =
  "Text me booking confirmations, reminders and waitlist offers from ONE Fitness. " +
  "Message frequency varies. Message and data rates may apply. " +
  "Reply STOP to unsubscribe or HELP for help. See our Terms of Use and Privacy Policy. " +
  "(opted in by replying START)";

/// TwiML. Twilio's own Advanced Opt-Out usually sends the STOP/START
/// confirmation itself; returning an empty response then avoids a duplicate
/// text. HELP is answered here so the reply names a real human route.
function twiml(message?: string): Response {
  const body = message
    ? `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeXml(message)}</Message></Response>`
    : `<?xml version="1.0" encoding="UTF-8"?><Response></Response>`;
  return new Response(body, { headers: { "Content-Type": "text/xml" } });
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/// US-style numbers as typed ("818-223-7001") -> +18182237001 for Twilio.
function toE164(raw: string): string | null {
  const d = raw.replace(/\D/g, "");
  if (raw.trim().startsWith("+") && d.length >= 8) return `+${d}`;
  if (d.length === 10) return `+1${d}`;
  if (d.length === 11 && d.startsWith("1")) return `+${d}`;
  return null;
}

function last4(from: string): string {
  const digits = from.replace(/\D/g, "");
  return digits.slice(-4) || "unknown";
}

// deno-lint-ignore no-explicit-any
async function notifyOwnersOfInbound(admin: any, label: string, body: string, skipIds: string[]): Promise<void> {
  try {
    const { data: owners, error } = await admin.from("profiles").select("id").eq("role", "owner");
    if (error) {
      console.warn("sms-inbound: owner lookup skipped:", error.message);
      return;
    }
    const skip = new Set(skipIds);
    const snippet = body.length > 140 ? `${body.slice(0, 137)}...` : body;
    for (const owner of owners ?? []) {
      const id = owner.id as string;
      if (!id || skip.has(id)) continue;
      const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", id);
      const tokens = (rows ?? []).map((row: { token: string }) => row.token).filter(Boolean);
      await sendPush(tokens, "Text to the gym number", `${label}: ${snippet}`);
    }
  } catch (e) {
    console.warn("sms-inbound: owner push skipped:", e instanceof Error ? e.message : String(e));
  }
}

// deno-lint-ignore no-explicit-any
async function coachRepliedWithinQuietHours(admin: any, clientId: string, coachId: string): Promise<boolean> {
  const { data, error } = await admin
    .from("messages")
    .select("created_at")
    .eq("client_id", clientId)
    .eq("sender_id", coachId)
    .eq("who", "trainer")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) {
    console.warn("sms-inbound: quiet-window lookup skipped:", error.message);
    return false;
  }
  return autoReplySuppressed((data?.created_at as string | null) ?? null);
}

export async function handleInbound(req: Request): Promise<Response> {
  try {
    if (req.method !== "POST") return twiml();

    const raw = await req.text();
    const params: Record<string, string> = {};
    for (const [k, v] of new URLSearchParams(raw)) params[k] = v;

    // Twilio signs the public URL (https://<project>.supabase.co/functions/v1/<name>).
    // The edge runtime shows a shorter internal URL, so the public spelling
    // is tried too. TWILIO_WEBHOOK_URL, when set, is the first candidate.
    const override = Deno.env.get("TWILIO_WEBHOOK_URL") ?? null;
    const candidates = webhookCandidates({
      requestUrl: req.url,
      forwardedHost: req.headers.get("x-forwarded-host"),
      host: req.headers.get("host"),
      override,
      supabaseUrl: Deno.env.get("SUPABASE_URL") ?? null,
    });

    const signature = req.headers.get("x-twilio-signature") ?? "";
    const token = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
    let matched: string | null = null;
    for (const url of candidates) {
      if (await twilioSignatureMatches(token, url, params, signature)) {
        matched = url;
        break;
      }
    }
    if (!matched) {
      console.warn(
        `sms-inbound: signature matched none of ${candidates.length} candidates (webhook override ${override ? "set" : "unset"})`,
      );
      return new Response("Forbidden", { status: 403 });
    }
    console.log(`sms-inbound: signature matched ${describeWebhookUrl(matched, override)}`);

    const from = params["From"] ?? "";
    const keyword = (params["Body"] ?? "").trim().toUpperCase().replace(/[^A-Z]/g, "");
    if (!from || !keyword) return twiml();

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    if (HELP.has(keyword)) {
      return twiml(
        "ONE Fitness: for help call (818) 223-7001 or email info@onefitnessworkout.com. " +
        "Reply STOP to unsubscribe. Msg & data rates may apply.",
      );
    }

    const optOut = OPT_OUT.has(keyword);
    const optIn = OPT_IN.has(keyword);

    const { data: profileId, error } = await admin.rpc("profile_id_by_phone", { raw_phone: from });
    if (error) throw error;

    // Not a keyword — someone replying to a text. Their words belong in the
    // conversation, where their coach will actually see them; until now
    // these replies arrived at Twilio and went nowhere, so a client
    // answering a booking reminder was talking to a wall.
    if (!optOut && !optIn) {
      const body = (params["Body"] ?? "").trim();
      if (!profileId) {
        console.warn(`sms-inbound: reply from ${from} matched no single client`);
        await notifyOwnersOfInbound(admin, last4(from), body, []);
        return twiml();
      }
      if (!body) return twiml();

      // The thread it belongs to: the coach who last wrote to this client,
      // else their own coach. (Using only the primary coach lost replies for
      // every client without one, and for anyone a different coach texted.)
      let trainerId: string | null = null;
      // Who actually sent the last message the client is answering: that
      // person decides where the reply is routed (see below).
      const { data: last } = await admin.from("messages")
        .select("trainer_id, sender_id").eq("client_id", profileId).eq("who", "trainer")
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      const lastSenderId = (last?.sender_id as string | null) ?? null;
      trainerId = (last?.trainer_id as string | null) ?? null;
      if (!trainerId) {
        const { data: client } = await admin
          .from("clients").select("primary_trainer_id").eq("profile_id", profileId).maybeSingle();
        trainerId = (client?.primary_trainer_id as string | null) ?? null;
      }

      const { error: msgErr } = await admin.from("messages").insert({
        client_id: profileId,
        trainer_id: trainerId,
        sender_id: profileId,
        who: "client",
        body,
        channel: "sms",
      });
      if (msgErr) {
        // The content filter and the block rules run on insert, so a
        // rejection here is the system working. Nothing is echoed back:
        // telling someone by SMS which word tripped a filter invites
        // probing, and the reply still reached a human at Twilio.
        console.warn(`sms-inbound: reply from ${profileId} not stored: ${msgErr.message}`);
        await notifyOwnersOfInbound(admin, last4(from), body, []);
        return twiml();
      }

      // Routing of a client's reply:
      //   - the last message came from the OWNER  -> the app chat only
      //     (the owner is notified by push).
      //   - the last message came from a COACH    -> the app chat AND the
      //     coach's own phone number (a text from the gym number).
      let label = last4(from);
      let coachId: string | null = null;
      const alreadyPushed: string[] = [];
      try {
        const { data: who } = await admin.from("profiles").select("name").eq("id", profileId).maybeSingle();
        const accountName = ((who?.name as string | undefined) ?? "").trim();
        const clientName = accountName || "A client";
        label = accountName || last4(from);

        let sender: { id: string; role: string; phone: string | null } | null = null;
        const senderId = lastSenderId ?? trainerId;
        if (senderId) {
          const { data: sp } = await admin.from("profiles").select("id, role, phone").eq("id", senderId).maybeSingle();
          if (sp) sender = { id: sp.id as string, role: sp.role as string, phone: (sp.phone as string | null) ?? null };
        }

        let pushTo: string[] = sender ? [sender.id] : [];
        if (pushTo.length === 0) {
          const { data: owners } = await admin.from("profiles").select("id").eq("role", "owner");
          pushTo = (owners ?? []).map((o: { id: string }) => o.id);
        }
        alreadyPushed.push(...pushTo);
        for (const t of pushTo) {
          const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", t);
          await sendPush((rows ?? []).map((r: { token: string }) => r.token), `${clientName} (SMS)`, body);
        }

        if (sender?.role === "coach" && sender.phone) {
          const to = toE164(sender.phone);
          if (to) await sendSms(to, `${clientName}: ${body}`);
        }
        if (sender?.role === "coach") coachId = sender.id;
      } catch (e) {
        console.warn("sms-inbound: routing failed:", e instanceof Error ? e.message : String(e));
      }

      await notifyOwnersOfInbound(admin, label, body, alreadyPushed);
      console.log(`sms-inbound: stored an SMS reply from ${profileId} on thread ${trainerId ?? "none"}`);

      // The text is to a coach, so the client gets one sentence back by SMS.
      // There is no business text line: a reply aimed at the owner is stored
      // in the app and is not auto-texted. The same row is channel "sms", so
      // the chat trigger does not also post an in-app automatic note.
      if (coachId && !(await coachRepliedWithinQuietHours(admin, profileId, coachId))) {
        console.log("sms-inbound: sent coach auto-reply by SMS");
        return twiml(COACH_AUTO_REPLY);
      }
      if (coachId) console.log("sms-inbound: coach auto-reply suppressed (coach replied inside the quiet window)");
      return twiml();
    }

    if (!profileId) {
      // Unmatched or ambiguous. Twilio still honours the opt-out at its own
      // level, so the person is protected either way; this is logged so it
      // can be reconciled by hand.
      console.warn(`sms-inbound: ${keyword} from ${from} matched no single client`);
      return twiml();
    }

    const now = new Date().toISOString();
    const { error: updateErr } = await admin.from("clients").update({
      sms_opt_in: optIn,
      sms_opt_in_at: optIn ? now : null,
      sms_consent_text: optIn ? CONSENT_TEXT : null,
    }).eq("profile_id", profileId);
    if (updateErr) throw updateErr;

    console.log(`sms-inbound: ${profileId} ${optIn ? "opted in" : "opted out"} via ${keyword}`);

    // Empty reply: Twilio's Advanced Opt-Out sends its own confirmation for
    // STOP/START, and two texts for one keyword looks broken.
    return twiml();
  } catch (e) {
    console.error("sms-inbound failed:", e instanceof Error ? e.message : String(e));
    // Always 200 with empty TwiML on our own errors: a 500 makes Twilio
    // retry, and a retried STOP achieves nothing but noise.
    return twiml();
  }
}
