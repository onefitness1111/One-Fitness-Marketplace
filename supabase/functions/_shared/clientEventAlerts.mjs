// Alerts a client's own action sends to staff (new booking, cancel, sign-up,
// measurement, intake, exercise swap). Pure rules only; send-push does the database reads.
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
  ["Exercise swap", "swap"],
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
 *          measurementAt?, intakeFlag?, swap?: { logId, swapsAt, count },
 *          programCoachId? }
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
    case "swap": {
      // The app sends this to every coach. The server sends it once, to the
      // coach who wrote the program the session came from (matched by their
      // coach name), or to the owner when no coach can be matched.
      const sw = facts.swap;
      if (!sw?.logId || !(sw.count > 0) || !isRecent(sw.swapsAt, now, EVENT_WINDOW_MIN)) return null;
      const recipients = facts.programCoachId ? [facts.programCoachId] : owners;
      if (!recipients.length) return null;
      const n = Math.min(Math.floor(sw.count), 99);
      return {
        kind: "swap",
        ref: `swap:${sw.logId}:${sw.swapsAt}`,
        recipients,
        title: "Exercise swap",
        body: `${name} swapped ${n} exercise${n === 1 ? "" : "s"} in today's workout. The program was not changed.`,
      };
    }
    default:
      return null;
  }
}

/** Case-insensitive, trimmed coach-name match; blank never matches. */
export function sameCoachName(a, b) {
  const x = String(a ?? "").trim().toLowerCase();
  const y = String(b ?? "").trim().toLowerCase();
  return x !== "" && x === y;
}

/**
 * The app names one recipient per call. For most alerts it must be one the
 * server chose. The swap alert is fanned out by the app to every coach, so
 * any staff member is an acceptable target; the server still sends only to
 * its own recipients, once.
 */
export function callerTargetAllowed(alert, profileId, targetRole) {
  if (!alert) return false;
  if (alert.kind === "swap") return targetRole === "coach" || targetRole === "owner";
  return alert.recipients.includes(String(profileId ?? "").trim());
}
