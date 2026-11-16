// Automatic replies to a client who just messaged a coach or the business.
//
// The sentences and the quiet window are named here so they are easy to
// edit. The database trigger in
// supabase/migrations/20261116230000_chat_auto_reply.sql repeats the same
// three values — keep the two copies identical.

/** Sent when the message is to a coach. */
export const COACH_AUTO_REPLY =
  "Hey, your coach has received your message and will get back to you ASAP.";

/**
 * Sent when the message is to the business, the owner, or anyone who is
 * not a coach. In-app only: this number is not a business text line, so
 * this sentence is never texted back.
 */
export const BUSINESS_AUTO_REPLY =
  "Hey, your message was received and we'll get back to you as soon as possible.";

/**
 * After the coach (or the business, for a non-coach thread) last wrote in
 * that conversation, this many hours pass before automatic replies start
 * again. While their latest human reply is newer than this, the client
 * gets no automatic reply. Every client message outside that window gets
 * one. Automatic notes do not count as a reply.
 */
export const AUTO_REPLY_QUIET_HOURS = 6;

const QUIET_MS = AUTO_REPLY_QUIET_HOURS * 60 * 60 * 1000;

/**
 * True when [lastHumanReplyAt] (an ISO timestamp of the recipient's newest
 * real message in the conversation) is under [AUTO_REPLY_QUIET_HOURS] old.
 * A missing or unreadable timestamp means they have not replied, so an
 * automatic reply is due. Exactly on the boundary, replies resume.
 */
export function autoReplySuppressed(lastHumanReplyAt: string | null, nowMs = Date.now()): boolean {
  if (!lastHumanReplyAt) return false;
  const at = Date.parse(lastHumanReplyAt);
  if (Number.isNaN(at)) return false;
  const ageMs = nowMs - at;
  return ageMs < QUIET_MS;
}
