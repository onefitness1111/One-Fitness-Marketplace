// Texts the coach auto-reply to a client who sent a chat message to their
// coach in the app AND by SMS. Called only by the messages_auto_reply
// database trigger (through pg_net, after the message has committed); see
// supabase/migrations/20261116233000_chat_auto_reply_both_channels.sql.
//
// Deploy WITHOUT jwt verification: pg_net sends no JWT. Nothing in the
// request is trusted except a message id. Before texting, everything is
// re-read from the database with the service key:
//   - the message is a client's own message, under 10 minutes old, and SMS
//     was one of the channels the client picked;
//   - the trigger already posted the coach automatic note for it (so the
//     6-hour quiet window and every other rule has already been applied);
//   - it has not been answered by text before (chat_auto_reply_sms);
//   - the client has a usable number that is not a landline.
// So a replayed or guessed request can at most send the one reply that was
// due anyway, once.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { COACH_AUTO_REPLY } from "../_shared/autoReply.ts";

const MAX_AGE_MS = 10 * 60 * 1000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function toE164(raw: string): string | null {
  const d = raw.replace(/\D/g, "");
  if (raw.trim().startsWith("+") && d.length >= 8) return `+${d}`;
  if (d.length === 10) return `+1${d}`;
  if (d.length === 11 && d.startsWith("1")) return `+${d}`;
  return null;
}

/** "inapp,sms" etc., plus the old spellings the app still reads. */
function channelHasSms(channel: string | null): boolean {
  const tokens = (channel ?? "").toLowerCase().split(",").map((t) => t.trim()).filter(Boolean);
  return tokens.includes("sms") || tokens.includes("inappsms") || tokens.includes("both");
}

/** Twilio Lookup line type. null when the lookup itself failed. */
async function lineType(sid: string, token: string, e164: string): Promise<string | null> {
  try {
    const res = await fetch(
      `https://lookups.twilio.com/v2/PhoneNumbers/${encodeURIComponent(e164)}?Fields=line_type_intelligence`,
      { headers: { Authorization: `Basic ${btoa(`${sid}:${token}`)}` } },
    );
    if (!res.ok) {
      console.warn(`chat-auto-reply-sms: line lookup failed (${res.status})`);
      return null;
    }
    const data = await res.json();
    return (data?.line_type_intelligence?.type as string | undefined) ?? null;
  } catch (e) {
    console.warn("chat-auto-reply-sms: line lookup failed:", e instanceof Error ? e.message : String(e));
    return null;
  }
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let messageId = "";
  try {
    const body = await req.json();
    messageId = String(body?.message_id ?? "");
  } catch (_) {
    // fall through
  }
  if (!UUID.test(messageId)) return json({ skipped: "bad request" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  // deno-lint-ignore no-explicit-any
  const record = async (outcome: string): Promise<any> => {
    await admin.from("chat_auto_reply_sms").update({ outcome }).eq("message_id", messageId);
    console.log(`chat-auto-reply-sms: ${messageId} ${outcome}`);
    return json({ outcome });
  };

  try {
    const { data: msg, error } = await admin
      .from("messages")
      .select("id, client_id, trainer_id, sender_id, who, channel, created_at")
      .eq("id", messageId)
      .maybeSingle();
    if (error) throw error;
    if (!msg || msg.who !== "client" || msg.sender_id !== msg.client_id) return json({ skipped: "not a client message" });
    if (!channelHasSms(msg.channel as string | null)) return json({ skipped: "sms not chosen" });
    const createdMs = Date.parse(msg.created_at as string);
    if (Number.isNaN(createdMs) || Date.now() - createdMs > MAX_AGE_MS) return json({ skipped: "too old" });

    // The trigger posts the coach note only when a reply is due.
    const windowEnd = new Date(createdMs + 5000).toISOString();
    const { data: note } = await admin
      .from("messages")
      .select("id")
      .eq("client_id", msg.client_id)
      .eq("who", "auto")
      .eq("body", COACH_AUTO_REPLY)
      .gte("created_at", msg.created_at)
      .lte("created_at", windowEnd)
      .limit(1)
      .maybeSingle();
    if (!note) return json({ skipped: "no reply due" });

    // Claim it. A second call for the same message stops here.
    const { error: claimErr } = await admin.from("chat_auto_reply_sms").insert({ message_id: messageId, outcome: "pending" });
    if (claimErr) {
      if ((claimErr as { code?: string }).code === "23505") return json({ skipped: "already answered" });
      throw claimErr;
    }

    const { data: profile } = await admin.from("profiles").select("phone").eq("id", msg.client_id).maybeSingle();
    const to = toE164(((profile?.phone as string | null) ?? "").trim());
    if (!to) return await record("skipped: no usable phone number");

    const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
    const token = Deno.env.get("TWILIO_AUTH_TOKEN");
    const from = Deno.env.get("TWILIO_FROM_NUMBER");
    if (!sid || !token || !from) return await record("skipped: twilio not configured");

    const type = await lineType(sid, token, to);
    if (type === "landline" || type === "fixedVoip") return await record(`skipped: ${type}`);

    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ To: to, From: from, Body: COACH_AUTO_REPLY }).toString(),
    });
    if (!res.ok) {
      const detail = await res.text();
      console.error(`chat-auto-reply-sms: Twilio ${res.status}: ${detail.slice(0, 300)}`);
      return await record(`failed: twilio ${res.status}`);
    }
    return await record(`sent (line ${type ?? "unknown"})`);
  } catch (e) {
    console.error("chat-auto-reply-sms failed:", e instanceof Error ? e.message : String(e));
    return json({ error: "failed" }, 500);
  }
});
