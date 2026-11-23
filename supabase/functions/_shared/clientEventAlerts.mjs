// Alerts a client's own action sends to staff (new booking, cancel, sign-up,
// measurement, intake). Pure rules only; send-push does the database reads.
//
// The app (1.1.2 and later) calls send-push once per staff recipient with a
// title and body it wrote itself. For a client caller the server keeps only
// the title, as a hint of which event happened. It then:
//   - finds that event in the database, made by this client, in the last
//     few minutes (so a client can only report something they really did),
//   - picks the recipients itself (the session's coach, or the owner),
//   - writes the title and body itself,
//   - sends each alert once (dedupe) and never by text message.
// Anything else from a client is refused, so a client can't message
// arbitrary people or send words of their own.

export const EVENT_WINDOW_MIN = 15;
export const SIGNUP_WINDOW_HOURS = 24;
export const CLIENT_ALERTS_PER_HOUR = 12;

const STAFF_TITLES = new Map([
  ["New booking", "booking"],
  ["Late cancel", "cancel"],
  ["Early cancel", "cancel"],
  ["New client", "signup"],
  ["Measurement logged", "measurement"],
  ["New nutrition program needed", "intake"],
  ["New training program needed", "intake"],
]);

/**
 * What a client's send-push call is about.
 * Returns { kind: "self" } for a notice the client sends to themself
 * (already confirmed by client-notify, so it is a no-op), one of the event
 * kinds for a staff alert, or { kind: null } to refuse.
 */
export function classifyClientPush({ callerId, profileId, title }) {
  const caller = String(callerId ?? "").trim();
  const target = String(profileId ?? "").trim();
  const t = String(title ?? "").trim();
  if (!caller || !target) return { kind: null };
  if (target === caller) return { kind: "self" };
  const kind = STAFF_TITLES.get(t) ?? null;
  if (kind === "intake") {
    return { kind, intakeKind: t.includes("nutrition") ? "nutrition" : "training" };
  }
  return { kind };
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Same wording as the app: "Tue, Nov 24 at 10:00 AM". */
export function formatWhen(isoDate, slotMin) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(isoDate ?? ""));
  let day = "";
  if (m) {
    const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
    day = `${WEEKDAYS[d.getUTCDay()]}, ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
  }
  const mins = Number(slotMin);
  if (!Number.isFinite(mins)) return day;
  const h = Math.floor(mins / 60);
  const mm = String(mins % 60).padStart(2, "0");
  const h12 = h % 12 === 0 ? 12 : h % 12;
  const time = `${h12}:${mm} ${h < 12 ? "AM" : "PM"}`;
  return day ? `${day} at ${time}` : time;
}

/** A display name safe to put in a push: one line, short, or "A client". */
export function safeName(name) {
  const clean = String(name ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (!clean) return "A client";
  return clean.length > 60 ? `${clean.slice(0, 59)}…` : clean;
}

export function isRecent(iso, nowMs, minutes) {
  const t = Date.parse(String(iso ?? ""));
  if (!Number.isFinite(t)) return false;
  return t <= nowMs + 60_000 && nowMs - t <= minutes * 60_000;
}

/**
 * Builds the alert from facts the server read. Returns null when the facts
 * don't show a real, recent event by this client.
 *
 * facts: { nowMs, clientName, owners: [id], booking?, cancel?, profileCreatedAt?,
 *          measurementAt?, intakeFlag? }
 */
export function buildAlert(classified, facts) {
  const now = facts.nowMs;
  const name = safeName(facts.clientName);
  const owners = [...new Set((facts.owners ?? []).filter(Boolean))];
  switch (classified.kind) {
    case "booking": {
      const b = facts.booking;
      if (!b?.id || !b.trainer_id || !isRecent(b.created_at, now, EVENT_WINDOW_MIN)) return null;
      return {
        kind: "booking",
        ref: `booking:${b.id}`,
        recipients: [b.trainer_id],
        title: "New booking",
        body: `${name} booked ${formatWhen(b.date, b.slot_min)}.`,
      };
    }
    case "cancel": {
      const c = facts.cancel;
      if (!c?.booking_id || !c.trainer_id || !isRecent(c.cancelled_at, now, EVENT_WINDOW_MIN)) return null;
      return {
        kind: "cancel",
        ref: `cancel:${c.booking_id}`,
        recipients: [c.trainer_id],
        title: c.status === "late-cancel" ? "Late cancel" : "Early cancel",
        body: `A client cancelled ${formatWhen(c.date, c.slot_min)}.`,
      };
    }
    case "signup": {
      if (!owners.length || !isRecent(facts.profileCreatedAt, now, SIGNUP_WINDOW_HOURS * 60)) return null;
      return { kind: "signup", ref: "signup", recipients: owners, title: "New client", body: `${name} signed up.` };
    }
    case "measurement": {
      if (!owners.length || !isRecent(facts.measurementAt, now, EVENT_WINDOW_MIN)) return null;
      return {
        kind: "measurement",
        ref: `measurement:${facts.measurementAt}`,
        recipients: owners,
        title: "Measurement logged",
        body: `${name} logged a measurement.`,
      };
    }
    case "intake": {
      const f = facts.intakeFlag;
      if (!owners.length || !f?.kind || !isRecent(f.flagged_at, now, EVENT_WINDOW_MIN)) return null;
      const nutrition = f.kind === "nutrition";
      return {
        kind: "intake",
        ref: `intake:${f.kind}:${f.flagged_at}`,
        recipients: owners,
        title: nutrition ? "New nutrition program needed" : "New training program needed",
        body: `${name} filed a new intake.`,
      };
    }
    default:
      return null;
  }
}

/** The app names one recipient per call; it must be one the server chose. */
export function callerTargetAllowed(alert, profileId) {
  return !!alert && alert.recipients.includes(String(profileId ?? "").trim());
}
