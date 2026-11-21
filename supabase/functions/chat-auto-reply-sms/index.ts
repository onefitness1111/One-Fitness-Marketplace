// Texts the other person when a chat message is saved.
//
// Deploying this replaces the live function. The live one texts
// "Hey, your coach has received your message and will get back to you ASAP."
// This one texts the message itself, prefixed with the sender's public name
// ("Coach Chris: …", a client's name, or "ONE Fitness Marketplace: …").
//
// Run the messaging migration first. Deploy with JWT verification OFF:
//   supabase functions deploy chat-auto-reply-sms --no-verify-jwt
// The database calls this with pg_net and does not send a JWT. The only
// input we trust is a message id. Everything else is re-read with the
// service key. A repeat call for the same message does not text twice.
//
// Likes never call this. A client who has opted out, or who has not agreed
// to texts, is not texted. A coach or the owner is texted when they have a
// phone and have not opted out. A client's message to staff is texted
// whatever channel the client picked. The app thread is unaffected.
// The staff push is claimed per message so client-notify does not push twice.

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { clientToStaff, planTextsForSavedMessage } from "../_shared/chatRouting.mjs";
import { lineType, loadCoaches, loadParty, toE164 } from "../_shared/chatPeople.ts";
import { sendSms } from "../_shared/sendSms.ts";
import { pushStaffForClientMessage } from "../_shared/staffAlert.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function channelHasSms(channel: string | null): boolean {
  const tokens = (channel ?? "").toLowerCase().split(",").map((t) => t.trim()).filter(Boolean);
  return tokens.includes("sms") || tokens.includes("inappsms") || tokens.includes("both");
}

// deno-lint-ignore no-explicit-any
function recipientId(msg: any, senderId: string): string | null {
  const clientId = msg.client_id as string | null;
  const trainerId = msg.trainer_id as string | null;
  if (senderId !== clientId && senderId !== trainerId) return trainerId;
  if (senderId === clientId) return trainerId;
  return clientId;
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let messageId = "";
  try {
    const body = await req.json();
    messageId = String(body?.message_id ?? "");
  } catch {
    // fall through
  }
  if (!UUID.test(messageId)) return json({ skipped: "bad request" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  const record = async (outcome: string) => {
    await admin.from("chat_auto_reply_sms").update({ outcome }).eq("message_id", messageId);
    console.log(`chat-auto-reply-sms: ${messageId} ${outcome}`);
    return json({ outcome });
  };

  try {
    const { error: claimErr } = await admin.from("chat_auto_reply_sms").insert({
      message_id: messageId,
      outcome: "pending",
    });
    if (claimErr) {
      if ((claimErr as { code?: string }).code === "23505") return json({ skipped: "already handled" });
      throw claimErr;
    }

    const { data: msg, error } = await admin
      .from("messages")
      .select("id, client_id, trainer_id, sender_id, who, body, channel, origin_channel, routed_to, group_name")
      .eq("id", messageId)
      .maybeSingle();
    if (error) throw error;
    if (!msg) {
      await admin.from("chat_auto_reply_sms").delete().eq("message_id", messageId);
      return json({ skipped: "missing" });
    }
    if (msg.who === "auto") return await record("skipped: not a person");

    const sender = await loadParty(admin, msg.sender_id as string);
    if (!sender) return await record("skipped: sender missing");

    const otherId = recipientId(msg, sender.id);
    let recipient = otherId ? await loadParty(admin, otherId) : null;
    if (!recipient && msg.routed_to === "business") {
      const { data: owner } = await admin.from("profiles").select("id").eq("role", "owner").is("deleted_at", null).limit(1).maybeSingle();
      if (owner?.id && owner.id !== sender.id) recipient = await loadParty(admin, owner.id as string);
    }

    const coaches = sender.role === "owner" ? await loadCoaches(admin) : [];
    const relayToStaff = clientToStaff(sender, recipient);
    const includeSms = relayToStaff || channelHasSms(msg.channel as string | null);
    const plan = planTextsForSavedMessage({
      sender,
      recipient,
      body: String(msg.body || ""),
      originChannel: (msg.origin_channel as string | null) || (msg.channel === "sms" ? "sms" : "app"),
      routedTo: (msg.routed_to as string | null) || (msg.trainer_id ? "conversation" : "business"),
      coaches,
      includeSms,
      groupName: msg.group_name,
    });

    for (const copy of plan.passAlong) {
      const { error: copyErr } = await admin.from("messages").insert({
        client_id: copy.clientId,
        trainer_id: copy.coachId,
        sender_id: sender.id,
        who: "trainer",
        body: copy.body,
        channel: msg.channel,
        read_by_coach: true,
      });
      if (copyErr) console.warn(`chat-auto-reply-sms: pass-along not saved: ${copyErr.message}`);
    }

    if (relayToStaff && recipient) {
      await pushStaffForClientMessage(admin, {
        messageId,
        staffId: recipient.id,
        clientName: sender.displayName,
        body: String(msg.body || ""),
      });
    }

    if (!includeSms) return await record("skipped: sms not chosen");
    if (plan.sms.length === 0) return await record("skipped: recipient cannot be texted");

    const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
    const token = Deno.env.get("TWILIO_AUTH_TOKEN");
    const from = Deno.env.get("TWILIO_FROM_NUMBER");
    if (!sid || !token || !from) return await record("skipped: twilio not configured");

    let sent = 0;
    for (const item of plan.sms) {
      const party = item.toId === recipient?.id ? recipient : await loadParty(admin, item.toId);
      const to = party ? toE164(party.phone) : null;
      if (!to) continue;
      const type = await lineType(sid, token, to);
      if (type === "landline" || type === "fixedVoip") {
        console.log(`chat-auto-reply-sms: skipped landline for ${item.toId}`);
        continue;
      }
      await sendSms(to, item.body);
      sent += 1;
    }
    return await record(sent > 0 ? `sent ${sent}` : "skipped: no mobile number");
  } catch (e) {
    console.error("chat-auto-reply-sms failed:", e instanceof Error ? e.message : String(e));
    return json({ error: "failed" }, 500);
  }
});
