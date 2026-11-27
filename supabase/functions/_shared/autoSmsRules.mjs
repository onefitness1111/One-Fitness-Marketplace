// Who may get an automatic text, and when. No database and no Twilio.
//
// Automatic = reminders, waitlist offers, coach time-off notices, broadcasts,
// quiet nudges, payment problems, booking notices. Not a person typing in
// chat (chat-auto-reply-sms has its own consent rules).
//
// TCPA: a client is texted only after they opted in (clients.sms_opt_in),
// never after STOP (profiles.sms_opted_out) or after turning texts off in
// the app (clients.sms_declined_at). Staff need only a phone and no STOP.
// Coach assignment is never an input.

import { smsQuietHours } from "./quietHours.mjs";
import { textableNumber } from "./phoneRules.mjs";

/**
 * @returns "send" | "defer" | "skip: no phone" | "skip: not a textable number"
 *   | "skip: replied STOP" | "skip: turned texts off" | "skip: not opted in"
 *   | "skip: number can't get texts"
 */
export function autoSmsDecision(person, now) {
  const phone = String(person?.phone ?? "").trim();
  if (!phone) return "skip: no phone";
  if (!textableNumber(phone)) return "skip: not a textable number";
  if (person?.optedOut === true) return "skip: replied STOP";
  if (person?.undeliverable === true) return "skip: number can't get texts";
  const staff = person?.role === "coach" || person?.role === "owner";
  if (!staff) {
    if (person?.declined === true) return "skip: turned texts off";
    if (person?.smsOptIn !== true) return "skip: not opted in";
  }
  return smsQuietHours(now) ? "defer" : "send";
}
