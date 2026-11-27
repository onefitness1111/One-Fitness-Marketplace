// Pacific-time helpers and the quiet hours for automatic texts.
//
// Coach Chris (Nov 27, 2026): no automatic text between 9:00pm and 8:00am
// Pacific. A text that would go out then waits until 8:00am. It is not
// dropped. Person-to-person chat texts are not automatic and are not held.
//
// Everything here is DST-proof: it asks Intl for the Pacific wall clock
// instead of adding a fixed UTC offset.

export const PACIFIC = "America/Los_Angeles";
export const QUIET_START_HOUR = 21;
export const QUIET_END_HOUR = 8;

const PARTS = new Intl.DateTimeFormat("en-US", {
  timeZone: PACIFIC,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  weekday: "short",
  hourCycle: "h23",
});

const WEEKDAYS = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

function toDate(now) {
  return now instanceof Date ? now : new Date(now ?? Date.now());
}

/** Pacific wall clock: { date: "YYYY-MM-DD", hour, minute, weekday (0 = Sunday), day } */
export function pacificParts(now) {
  const map = {};
  for (const part of PARTS.formatToParts(toDate(now))) map[part.type] = part.value;
  const hour = Number(map.hour) % 24;
  return {
    date: `${map.year}-${map.month}-${map.day}`,
    hour,
    minute: Number(map.minute),
    weekday: WEEKDAYS[map.weekday] ?? 0,
    day: Number(map.day),
    month: `${map.year}-${map.month}`,
  };
}

export function pacificHour(now) {
  return pacificParts(now).hour;
}

export function pacificDate(now) {
  return pacificParts(now).date;
}

/** Before 8:00am and from 9:00pm Pacific, an automatic text waits. */
export function smsQuietHours(now) {
  const hour = pacificHour(now);
  return hour < QUIET_END_HOUR || hour >= QUIET_START_HOUR;
}

/** "YYYY-MM-DD" plus n days, as a calendar date (no time zone involved). */
export function addDaysIso(dateIso, n) {
  const [y, m, d] = String(dateIso).split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return t.toISOString().slice(0, 10);
}

/**
 * The instant a Pacific wall-clock time happens: a booking's date plus
 * minutes after midnight. Works across DST because it corrects with the
 * offset Intl reports for that very day.
 */
export function pacificEpoch(dateIso, minutesAfterMidnight = 0) {
  const [y, m, d] = String(dateIso).split("-").map(Number);
  const mins = Number(minutesAfterMidnight) || 0;
  const guess = Date.UTC(y, m - 1, d, Math.floor(mins / 60), mins % 60);
  // Offset at the guess, then once more in case the guess crossed a DST edge.
  let at = guess;
  for (let i = 0; i < 2; i++) {
    const p = pacificParts(at);
    const [py, pm, pd] = p.date.split("-").map(Number);
    const shown = Date.UTC(py, pm - 1, pd, p.hour, p.minute);
    at = at + (guess - shown);
  }
  return at;
}

/** The next 8:00am Pacific at or after now. Now itself when outside quiet hours. */
export function quietHoursEnd(now) {
  const at = toDate(now).getTime();
  if (!smsQuietHours(at)) return new Date(at);
  const p = pacificParts(at);
  const day = p.hour >= QUIET_START_HOUR ? addDaysIso(p.date, 1) : p.date;
  return new Date(pacificEpoch(day, QUIET_END_HOUR * 60));
}
