// Writes the invite and sends what was held. The decision of who qualifies
// lives in smsInvite.mjs. This file only talks to the database and Twilio.
import { heldStaffTexts } from "./chatRouting.mjs";
import { toE164 } from "./chatPeople.ts";
import { inviteConsentRecord, INVITE_SMS_BODY } from "./smsInvite.mjs";
import { sendSms } from "./sendSms.ts";

// deno-lint-ignore no-explicit-any
type Admin = any;

export async function markMessageSmsPending(admin: Admin, messageId: string): Promise<void> {
  const { error } = await admin.from("messages").update({ sms_pending: true }).eq("id", messageId);
  if (error) console.warn(`sms invite: could not hold message ${messageId}: ${error.message}`);
}

/** Stamps the invite once. Null when another send already claimed it. */
export async function claimInviteSend(admin: Admin, profileId: string): Promise<string | null> {
  const at = new Date().toISOString();
  const { data, error } = await admin
    .from("clients")
    .update({ sms_invite_sent_at: at, sms_invite_text: INVITE_SMS_BODY })
    .eq("profile_id", profileId)
    .is("sms_invite_sent_at", null)
    .select("profile_id");
  if (error) {
    console.warn(`sms invite: claim failed: ${error.message}`);
    return null;
  }
  return data && data.length > 0 ? at : null;
}

export async function rollbackInviteSend(admin: Admin, profileId: string, at: string): Promise<void> {
  await admin
    .from("clients")
    .update({ sms_invite_sent_at: null, sms_invite_text: null })
    .eq("profile_id", profileId)
    .eq("sms_invite_sent_at", at);
}

/**
 * Records the YES. Returns false when someone else already did, or they
 * had declined. Does not write a chat message.
 */
export async function recordInviteYes(admin: Admin, profileId: string, inviteText: string | null): Promise<boolean> {
  const now = new Date().toISOString();
  const consent = inviteConsentRecord(inviteText || INVITE_SMS_BODY);
  const { data, error } = await admin
    .from("clients")
    .update({
      sms_opt_in: true,
      sms_opt_in_at: now,
      sms_consent_text: consent,
      sms_declined_at: null,
    })
    .eq("profile_id", profileId)
    .eq("sms_opt_in", false)
    .is("sms_declined_at", null)
    .select("profile_id");
  if (error) {
    console.warn(`sms invite: consent not saved: ${error.message}`);
    return false;
  }
  if (!data || data.length === 0) return false;
  const { error: profileErr } = await admin.from("profiles").update({
    sms_opted_out: false,
    sms_consent_at: now,
    sms_consent_text: consent,
  }).eq("id", profileId);
  if (profileErr) console.warn(`sms invite: profile consent not saved: ${profileErr.message}`);
  return true;
}

type Sender = { id: string; role: string; displayName: string };

/**
 * Texts every held staff message, oldest first, in the relay wording.
 * A row is claimed before it is sent so two YES handlers cannot double-text.
 */
export async function deliverHeldStaffSms(
  admin: Admin,
  profileId: string,
  phone: string,
  senderFor: (senderId: string) => Promise<Sender | null>,
): Promise<number> {
  const to = toE164(phone);
  if (!to) return 0;
  const { data: rows, error } = await admin
    .from("messages")
    .select("id, body, sender_id, who, origin_channel, routed_to, group_name, created_at")
    .eq("client_id", profileId)
    .eq("sms_pending", true)
    .order("created_at", { ascending: true });
  if (error) {
    console.warn(`sms invite: held messages not read: ${error.message}`);
    return 0;
  }
  const shaped = [];
  for (const row of rows ?? []) {
    const sender = await senderFor(row.sender_id as string);
    if (!sender) continue;
    shaped.push({
      id: row.id as string,
      who: row.who as string,
      smsPending: true,
      at: Date.parse(row.created_at as string),
      body: String(row.body || ""),
      sender,
      recipient: { id: profileId, role: "client" },
      originChannel: (row.origin_channel as string) || "app",
      routedTo: (row.routed_to as string) || "conversation",
      groupName: row.group_name as string | null,
    });
  }
  let sent = 0;
  for (const item of heldStaffTexts(shaped)) {
    const { data: claimed, error: claimErr } = await admin
      .from("messages")
      .update({ sms_pending: false })
      .eq("id", item.id)
      .eq("sms_pending", true)
      .select("id");
    if (claimErr || !claimed || claimed.length === 0) continue;
    const ok = await sendSms(to, item.body);
    if (!ok) {
      await admin.from("messages").update({ sms_pending: true }).eq("id", item.id);
      continue;
    }
    sent += 1;
  }
  return sent;
}
