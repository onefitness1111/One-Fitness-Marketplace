// Broadcast channel and audience rules. No database and no Twilio.
// The app copy is lib/core/utils/broadcast.dart. Keep the two in step.

export const BROADCAST_CHANNELS = ["app", "app_sms", "email"];

export function broadcastChannel(raw) {
  const value = String(raw || "").trim();
  return BROADCAST_CHANNELS.includes(value) ? value : null;
}

/** Old apps read "app", "app_sms", or "email". Any other mix is the chip list. */
export function broadcastSummaryChannel(ways) {
  if (!ways) return null;
  if (ways.app && ways.sms && !ways.email) return "app_sms";
  if (ways.app && !ways.sms && !ways.email) return "app";
  if (!ways.app && !ways.sms && ways.email) return "email";
  return [ways.app ? "inapp" : null, ways.sms ? "sms" : null, ways.email ? "email" : null]
    .filter(Boolean)
    .join(",");
}

/** Newlines become spaces. Empty means keep the coach-name prefix. */
export function sanitizeGroupName(raw) {
  const cleaned = String(raw ?? "").replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim();
  if (!cleaned) return "";
  return cleaned.length <= 40 ? cleaned : cleaned.slice(0, 40).trimEnd();
}

/** Chip names, or the older single channel string. Empty is not a send. */
export function broadcastWays(input) {
  const listed = Array.isArray(input?.channels) ? input.channels : Array.isArray(input) ? input : null;
  if (listed) {
    const names = new Set(listed.map((c) => String(c || "").trim()).filter(Boolean));
    const ways = { app: names.has("inapp"), sms: names.has("sms"), email: names.has("email") };
    return ways.app || ways.sms || ways.email ? ways : null;
  }
  const single = broadcastChannel(typeof input === "string" ? input : input?.channel);
  if (single === "app") return { app: true, sms: false, email: false };
  if (single === "app_sms") return { app: true, sms: true, email: false };
  if (single === "email") return { app: false, sms: false, email: true };
  return null;
}

export function scopeBroadcast({ senderIsOwner, senderId, all, requestedIds, clients }) {
  const mine = (clients || []).filter(() => {
    if (senderIsOwner) return true;
    return Boolean(String(senderId || "").trim());
  });
  if (all) return { allowed: mine, refused: [] };
  const byId = new Map(mine.map((c) => [c.id, c]));
  const allowed = [];
  const refused = [];
  for (const id of requestedIds || []) {
    const person = byId.get(id);
    if (!person) {
      if (String(id || "").trim()) refused.push(id);
    } else {
      allowed.push(person);
    }
  }
  return { allowed, refused };
}

export { pacificHour, smsQuietHours } from "./quietHours.mjs";
import { smsQuietHours } from "./quietHours.mjs";

export function canText(person) {
  const phone = String(person?.phone || "").trim();
  return Boolean(phone) && person?.smsOptIn === true && person?.smsOptedOut !== true;
}

export function previewBroadcast({ ways, recipients, now, refused = 0 }) {
  let sms = 0;
  let skippedNoPhone = 0;
  let skippedOptOut = 0;
  let smsLater = 0;
  let email = 0;
  let skippedNoEmail = 0;
  const quiet = smsQuietHours(now);
  const appOn = ways?.app === true;
  const smsOn = ways?.sms === true;
  const emailOn = ways?.email === true;
  for (const person of recipients || []) {
    if (smsOn) {
      if (!String(person.phone || "").trim()) skippedNoPhone += 1;
      else if (person.smsOptIn !== true || person.smsOptedOut === true) skippedOptOut += 1;
      else if (quiet) smsLater += 1;
      else sms += 1;
    }
    if (emailOn) {
      if (String(person.email || "").trim()) email += 1;
      else skippedNoEmail += 1;
    }
  }
  return {
    recipients: (recipients || []).length,
    app: appOn ? (recipients || []).length : 0,
    sms,
    email,
    skippedNoPhone,
    skippedOptOut,
    smsLater,
    skippedNoEmail,
    refused,
  };
}
