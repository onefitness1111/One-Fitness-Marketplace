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
// Likes never call this. A client who already agreed is texted the message.
// A client who has never answered is not texted an invite unless every
// gate passes: never invited, sms_declined_at is null, not opted out, and
// app_config.sms_invite_enabled is true. That flag defaults to false, so
// the message stays in the app until Coach Chris turns invites on. STOP,
// an opt-out, or turning texts off gets nothing. "Not now" is not a decline.
// Staff (the owner or any coach) text the client on the thread, even when
// trainer_id is a different coach. A client's message still texts staff.
// Coach assignment is not checked. The app thread is unaffected.
// The staff push is claimed per message so client-notify does not push twice.

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { clientToStaff, planTextsForSavedMessage, smsRecipientId } from "../_shared/chatRouting.mjs";
import { lineType, loadCoaches, loadParty, toE164 } from "../_shared/chatPeople.ts";
import {
  claimInviteSend,
  deliverHeldStaffSms,
  markMessageSmsPending,
  rollbackInviteSend,
} from "../_shared/inviteSms.ts";
import { sendSms } from "../_shared/sendSms.ts";
import { INVITE_SMS_BODY, smsInviteEnabledFlag } from "../_shared/smsInvite.mjs";
import { pushStaffForClientMessage } from "../_shared/staffAlert.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function channelHasSms(channel: string | null): boolean {
  const tokens = (channel ?? "").toLowerCase().split(",").map((t) => t.trim()).filter(Boolean);
  return tokens.includes("sms") || tokens.includes("inappsms") || tokens.includes("both");
}

// Missing row, a failed read, or anything other than boolean true stays off.
// deno-lint-ignore no-explicit-any
async function loadSmsInviteEnabled(admin: any): Promise<boolean> {
  try {
    const { data, error } = await admin
      .from("app_config")
      .select("sms_invite_enabled")
      .eq("id", "mobile")
      .maybeSingle();
    if (error) return false;
    return smsInviteEnabledFlag(data);
  } catch {
    return false;
  }
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

    const otherId = smsRecipientId({
      sender,
      clientId: msg.client_id as string | null,
      trainerId: msg.trainer_id as string | null,
    });
    let recipient = otherId ? await loadParty(admin, otherId) : null;
    if (!recipient && msg.routed_to === "business") {
      const { data: owner } = await admin.from("profiles").select("id").eq("role", "owner").is("deleted_at", null).limit(1).maybeSingle();
      if (owner?.id && owner.id !== sender.id) recipient = await loadParty(admin, owner.id as string);
    }

    const coaches = sender.role === "owner" ? await loadCoaches(admin) : [];
    const relayToStaff = clientToStaff(sender, recipient);
    const includeSms = relayToStaff || channelHasSms(msg.channel as string | null);
    const inviteEnabled = await loadSmsInviteEnabled(admin);
    const plan = planTextsForSavedMessage({
      sender,
      recipient,
      body: String(msg.body || ""),
      originChannel: (msg.origin_channel as string | null) || (msg.channel === "sms" ? "sms" : "app"),
      routedTo: (msg.routed_to as string | null) || (msg.trainer_id ? "conversation" : "business"),
      coaches,
      includeSms,
      groupName: msg.group_name,
      inviteEnabled,
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

    if (plan.clientSms === "disabled" || (plan.clientSms === "invite" && inviteEnabled !== true)) {
      const to = recipient ? toE164(recipient.phone) : null;
      if (!to) return await record("skipped: no mobile number");
      await markMessageSmsPending(admin, messageId);
      return await record("held: invites off");
    }

    if (plan.clientSms === "invite" || plan.clientSms === "hold") {
      const to = recipient ? toE164(recipient.phone) : null;
      if (!to) return await record("skipped: no mobile number");
      const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
      const token = Deno.env.get("TWILIO_AUTH_TOKEN");
      const from = Deno.env.get("TWILIO_FROM_NUMBER");
      if (sid && token) {
        const type = await lineType(sid, token, to);
        if (type === "landline" || type === "fixedVoip") return await record("skipped: no mobile number");
      }
      await markMessageSmsPending(admin, messageId);
      if (plan.clientSms === "hold") return await record("held: waiting for yes");
      if (!sid || !token || !from) return await record("skipped: twilio not configured");
      const claimedAt = recipient ? await claimInviteSend(admin, recipient.id) : null;
      if (!claimedAt) return await record("held: invite already sent");
      const invited = await sendSms(to, INVITE_SMS_BODY);
      if (!invited) {
        await rollbackInviteSend(admin, recipient!.id, claimedAt);
        return await record("skipped: invite not sent");
      }
      return await record("invite sent");
    }

    if (plan.sms.length === 0) return await record("skipped: recipient cannot be texted");

    const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
    const token = Deno.env.get("TWILIO_AUTH_TOKEN");
    const from = Deno.env.get("TWILIO_FROM_NUMBER");
    if (!sid || !token || !from) return await record("skipped: twilio not configured");

    // Messages held before they agreed go out first, in thread order.
    if (recipient?.role === "client" && recipient.hasConsent === true && recipient.optedOut !== true && recipient.declined !== true) {
      await deliverHeldStaffSms(admin, recipient.id, recipient.phone, async (senderId: string) => {
        if (senderId === sender.id) return { id: sender.id, role: sender.role, displayName: sender.displayName };
        const party = await loadParty(admin, senderId);
        if (!party) return null;
        return { id: party.id, role: party.role, displayName: party.displayName };
      });
    }

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
      const ok = await sendSms(to, item.body);
      if (ok) sent += 1;
    }
    return await record(sent > 0 ? `sent ${sent}` : "skipped: no mobile number");
  } catch (e) {
    console.error("chat-auto-reply-sms failed:", e instanceof Error ? e.message : String(e));
    return json({ error: "failed" }, 500);
  }
});
