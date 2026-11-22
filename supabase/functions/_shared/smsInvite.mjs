// One invite text for a client who has never answered, and the YES that
// accepts it. No database and no Twilio. Coach assignment is not an input.
//
// "Not now" on the in-app card is not a decline. It is not stored here.
// A decline is clients.sms_declined_at (they turned Text messages off),
// or profiles.sms_opted_out (STOP).
//
// An invite is not sent unless every gate below is true. The server flag
// defaults to off, so a missing row is not a yes.

export const INVITE_SMS_BODY =
  "ONE Fitness: Your coach sent you a message in the ONE Fitness app. Reply YES to receive it. Reply STOP to opt out.";

export const INVITE_SMS_VERSION = "2026-11-21";

export const INVITE_YES_CONFIRMATION =
  "ONE Fitness: You're opted in. We'll text you the messages from your coach. Reply STOP to opt out.";

/** What is stored on the client and the profile when they reply YES. */
export function inviteConsentRecord(inviteText = INVITE_SMS_BODY) {
  const text = String(inviteText || "").trim() || INVITE_SMS_BODY;
  return `Replied YES to invite SMS. ${text} (v${INVITE_SMS_VERSION})`;
}

/**
 * The whole text is an acceptance of the invite.
 * YES, Y, yes!, and "ok yes", in any case. A longer sentence is a real reply.
 */
export function isInviteYes(body) {
  const cleaned = String(body ?? "")
    .trim()
    .toLowerCase()
    .replace(/[.!]+$/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned === "y" || cleaned === "yes" || cleaned === "ok yes";
}

/** True only for the boolean stored on app_config.sms_invite_enabled. */
export function smsInviteEnabledFlag(row) {
  return row?.sms_invite_enabled === true;
}

/**
 * An invite may be sent only when every one of these is true:
 * a mobile number, never invited, sms_declined_at is null, not opted out,
 * they have not already agreed, and app_config.sms_invite_enabled is true.
 * The flag defaults to false. primaryTrainerId is ignored.
 */
export function inviteEligible(client, { inviteEnabled = false } = {}) {
  const phone = String(client?.phone || "").trim();
  if (!phone) return false;
  if (client?.optedOut === true || client?.declined === true) return false;
  if (client?.hasConsent === true) return false;
  if (String(client?.inviteSentAt || "").trim()) return false;
  return inviteEnabled === true;
}

/**
 * What to do with a staff SMS to a client.
 * send: they already agreed, text the message.
 * invite: never answered, and every invite gate passed. Text the invite once.
 * hold: the invite already went out. Keep the message, do not text again.
 * disabled: they would have been invited, but the server flag is off.
 *   Keep the message. Do not text.
 * skip: no number, STOP / opted out, or they declined in the app.
 *
 * primaryTrainerId is ignored on purpose. Any coach, or the owner, can
 * reach any client.
 */
export function staffClientSmsAction(client, options = {}) {
  const phone = String(client?.phone || "").trim();
  if (!phone) return "skip";
  if (client?.optedOut === true || client?.declined === true) return "skip";
  if (client?.hasConsent === true) return "send";
  if (String(client?.inviteSentAt || "").trim()) return "hold";
  if (inviteEligible(client, options)) return "invite";
  return "disabled";
}
