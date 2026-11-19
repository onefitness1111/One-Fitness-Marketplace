// Broadcast channel and audience rules. No database and no Twilio.
// The app copy is lib/core/utils/broadcast.dart. Keep the two in step.

export const BROADCAST_CHANNELS = ["app", "app_sms", "email"];

export function broadcastChannel(raw) {
  const value = String(raw || "").trim();
  return BROADCAST_CHANNELS.includes(value) ? value : null;
}

/** A chip set is allowed only for app, app+sms, or email alone. */
export function broadcastChannelFromSet(channels) {
  const names = new Set((channels || []).map((c) => String(c || "").trim()).filter(Boolean));
  if (names.size === 1 && names.has("inapp")) return "app";
  if (names.size === 2 && names.has("inapp") && names.has("sms")) return "app_sms";
  if (names.size === 1 && names.has("email")) return "email";
  return null;
}

export function scopeBroadcast({ senderIsOwner, senderId, all, requestedIds, clients }) {
  const mine = (clients || []).filter((c) => {
    if (senderIsOwner) return true;
    return Boolean(senderId) && String(c.primaryTrainerId || "") === senderId;
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

export function pacificHour(now) {
  const hour = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    hour: "numeric",
    hourCycle: "h23",
  }).format(now instanceof Date ? now : new Date(now));
  return Number(hour);
}

/** Before 8:00am and from 9:00pm Pacific, a text waits. App chat still sends. */
export function smsQuietHours(now) {
  const hour = pacificHour(now);
  return hour < 8 || hour >= 21;
}

export function canText(person) {
  const phone = String(person?.phone || "").trim();
  return Boolean(phone) && person?.smsOptIn === true && person?.smsOptedOut !== true;
}

export function previewBroadcast({ channel, recipients, now, refused = 0 }) {
  let sms = 0;
  let skippedNoPhone = 0;
  let skippedOptOut = 0;
  let skippedQuietHours = 0;
  let email = 0;
  let skippedNoEmail = 0;
  const quiet = smsQuietHours(now);
  for (const person of recipients || []) {
    if (channel === "email") {
      if (String(person.email || "").trim()) email += 1;
      else skippedNoEmail += 1;
      continue;
    }
    if (channel === "app_sms") {
      if (!String(person.phone || "").trim()) skippedNoPhone += 1;
      else if (person.smsOptIn !== true || person.smsOptedOut === true) skippedOptOut += 1;
      else if (quiet) skippedQuietHours += 1;
      else sms += 1;
    }
  }
  return {
    recipients: (recipients || []).length,
    app: channel === "email" ? 0 : (recipients || []).length,
    sms,
    email,
    skippedNoPhone,
    skippedOptOut,
    skippedQuietHours,
    skippedNoEmail,
    refused,
  };
}
