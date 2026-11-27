// When each scheduled reminder goes out. No database, no Stripe, no Twilio.
// send-scheduled-reminders runs every hour on the hour and asks this file
// what is due. Every time is Pacific wall-clock time (DST-proof).
//
// Coach Chris (Nov 27, 2026):
// - Session reminder about 24 hours before each session. One per booking.
// - Habit reminder in the evening (7pm Pacific), only to clients who have
//   habits and have not logged that day.
// - Challenges, to participants only: when the challenge is created (or
//   they are added), Monday morning, and 2 days before it closes.
// - 1st of the month: card-expiring warning and monthly review, after 8am.
// - Nothing goes out 9pm-8am. A reminder that comes due then goes out at
//   8:00am.

import { addDaysIso, pacificEpoch, pacificParts, smsQuietHours } from "./quietHours.mjs";

export const HABIT_HOUR = 19;
export const WEEKLY_CHALLENGE_HOUR = 8;
export const CLOSING_CHALLENGE_HOUR = 8;
export const MONTHLY_HOUR = 9;
export const SESSION_LEAD_MS = 24 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;

/** Which parts of the hourly run are due now. */
export function reminderPlan(now) {
  const p = pacificParts(now);
  const quiet = smsQuietHours(now);
  return {
    today: p.date,
    month: p.month,
    quiet,
    drainQueue: !quiet,
    sessions: !quiet,
    challengeCreated: !quiet,
    habits: p.hour === HABIT_HOUR,
    challengeWeekly: p.weekday === 1 && p.hour === WEEKLY_CHALLENGE_HOUR,
    challengeClosing: p.hour === CLOSING_CHALLENGE_HOUR,
    monthly: p.day === 1 && p.hour === MONTHLY_HOUR,
  };
}

/**
 * A booking's reminder is due once its session is 24 hours away or less,
 * and more than an hour away. A booking made less than a day ahead does not
 * get one (the booking confirmation just went out).
 */
export function sessionReminderDue({ date, slotMin, createdAt }, now) {
  const at = now instanceof Date ? now.getTime() : Number(now);
  const start = pacificEpoch(date, slotMin ?? 0);
  const lead = start - at;
  if (!(lead > HOUR_MS && lead <= SESSION_LEAD_MS)) return false;
  if (createdAt) {
    const made = Date.parse(createdAt);
    if (!Number.isNaN(made) && start - made < SESSION_LEAD_MS) return false;
  }
  return true;
}

/** "6:30 PM" for minutes after midnight. */
export function slotLabel(slotMin) {
  const minutes = Number(slotMin) || 0;
  const hour = Math.floor(minutes / 60);
  const minute = minutes % 60;
  return `${hour % 12 === 0 ? 12 : hour % 12}:${String(minute).padStart(2, "0")} ${hour < 12 ? "AM" : "PM"}`;
}

/** "today" or "tomorrow" or the date, as the client reads it. */
export function sessionDayWord(date, today) {
  if (date === today) return "today";
  if (date === addDaysIso(today, 1)) return "tomorrow";
  return `on ${date}`;
}

/** Participant ids on a challenge row (participants is a jsonb array of ids). */
export function challengeParticipants(row) {
  const list = Array.isArray(row?.participants) ? row.participants : [];
  return [...new Set(list.map((id) => String(id ?? "").trim()).filter(Boolean))];
}

export function challengeActive(row, today) {
  return Boolean(row?.start_date && row?.end_date && row.start_date <= today && today <= row.end_date);
}

export function challengeOpen(row, today) {
  return Boolean(row?.end_date && today <= row.end_date) && row?.status !== "ended" && row?.status !== "cancelled";
}

export function challengeClosesInTwoDays(row, today) {
  return Boolean(row?.end_date && row.end_date === addDaysIso(today, 2));
}

/** Habits on the client record, and whether today's log exists. */
export function habitReminderDue(record, today) {
  const data = record || {};
  const hasHabits = (Array.isArray(data.habits) && data.habits.length > 0) ||
    (Array.isArray(data.customHabits) && data.customHabits.length > 0);
  if (!hasHabits) return false;
  const logged = (data.habitLogByDate || {})[today];
  if (!logged) return true;
  if (typeof logged === "object") return Object.keys(logged).length === 0;
  return false;
}
