// Membership freeze rules, shared by freeze-membership, unfreeze-membership,
// apply-due-requests, stripe-webhook and the month-end rollover.
//
// Dates are plain "YYYY-MM-DD" days in America/Los_Angeles.
// A freeze runs from its start day (frozen) up to its end day. The end day
// is the first day the client can book again.
//
// While frozen nobody is charged: every Stripe subscription the client has
// is paused with behavior "void", so a renewal inside the freeze is voided.
// The billing day never moves.
//
// Sessions held through a freeze: when a freeze starts, each active
// membership's unused sessions for that month are written onto the plan
// entry as heldSessions. After the freeze they can be used from heldFrom
// (the end day) until heldUntil (the next billing day on or after it). On
// that billing day the normal charge runs and the normal allowance is back.
// Sessions rolled over from an earlier month are not held. They still
// expire with their own month.

import { wallTimeToUtc } from "./calendarFeed.mjs";
import { clampAnchorDay } from "./billingAnchor.mjs";
import { baseSessionAllowance, pacificCalendar, planKind } from "./membershipRollover.mjs";

export const FREEZE_TIME_ZONE = "America/Los_Angeles";

const MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function pacificToday(now = new Date()) {
  return pacificCalendar(now).date;
}

function isIsoDay(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

/// "Dec 22", the way the client is told when their freeze ends.
export function shortDay(isoDay) {
  if (!isIsoDay(isoDay)) return String(isoDay ?? "");
  const [, m, d] = isoDay.split("-").map(Number);
  return `${MONTHS_SHORT[m - 1]} ${d}`;
}

/// When Stripe should start collecting again, as a unix timestamp.
///
/// One hour before 12:00 AM Pacific on the end day. A renewal whose billing
/// day is the end day is created at 12:00 AM Pacific, after collection has
/// resumed, so it is charged normally and not voided. The old value (12:00
/// UTC on the end day, 4 or 5 AM Pacific) voided that renewal.
export function freezeResumesAt(endDay) {
  if (!isIsoDay(endDay)) throw new Error("The end date must be YYYY-MM-DD.");
  const midnight = wallTimeToUtc(endDay, 0, FREEZE_TIME_ZONE);
  return Math.floor(midnight.getTime() / 1000) - 3600;
}

/// True when the freeze has to wait for its start day instead of starting now.
export function freezeStartsLater(startDay, today) {
  return isIsoDay(startDay) && isIsoDay(today) && startDay > today;
}

/// True when [day] is inside the freeze: on or after the start, before the end.
export function freezeCovers(startDay, endDay, day) {
  if (!isIsoDay(day)) return false;
  if (isIsoDay(startDay) && day < startDay) return false;
  if (isIsoDay(endDay) && day >= endDay) return false;
  return true;
}

function addMonthsClamped(isoDay, months, dayOfMonth) {
  const [y, m] = isoDay.split("-").map(Number);
  const index = y * 12 + (m - 1) + months;
  const year = Math.floor(index / 12);
  const month = (index % 12) + 1;
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const day = Math.min(dayOfMonth, last);
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

/// The first billing day on or after [isoDay].
///
/// [anchorDay] is the client's billing day of the month (1 to 28). With no
/// billing day on file, the held sessions last one month from [isoDay].
export function nextBillingOnOrAfter(isoDay, anchorDay) {
  if (!isIsoDay(isoDay)) return null;
  const day = clampAnchorDay(anchorDay);
  const [, , d] = isoDay.split("-").map(Number);
  if (day == null) return addMonthsClamped(isoDay, 1, d);
  const thisMonth = addMonthsClamped(isoDay, 0, day);
  return thisMonth >= isoDay ? thisMonth : addMonthsClamped(isoDay, 1, day);
}

/// The billing day of the month from a Stripe subscription's
/// billing_cycle_anchor (unix seconds), read in Pacific time.
export function anchorDayFromStripe(billingCycleAnchor) {
  const n = Number(billingCycleAnchor);
  if (!Number.isFinite(n) || n <= 0) return null;
  return clampAnchorDay(pacificCalendar(new Date(n * 1000)).day);
}

const NOT_COUNTED = new Set(["early-cancel", "late-cancel"]);

/// Bookings on [planId] dated in [month] that hold a spot: not cancelled,
/// not an early or late cancel, not a physical assessment.
export function bookingsTowardLimit(bookings, planId, month) {
  let n = 0;
  for (const b of bookings || []) {
    const id = b.planId ?? b.plan_id;
    if (id !== planId || String(id).startsWith("single:")) continue;
    if (b.cancelled || b.cancelledAt || b.cancelled_at || b.status === "cancelled") continue;
    if (b.isPhysicalAssessment || b.is_physical_assessment) continue;
    const attendance = b.attendanceStatus ?? b.attendance_status ?? b.attendance ?? "";
    if (NOT_COUNTED.has(attendance)) continue;
    if (!String(b.date || "").startsWith(month)) continue;
    n += 1;
  }
  return n;
}

/// Unused sessions of [month]'s own allowance on one membership.
///
/// Rolled-over sessions are spent first, since they expire sooner, and are
/// never held themselves.
export function heldSessionsFor(plan, enrollment, bookings, month, legacy) {
  if (planKind(plan) !== "membership") return 0;
  const base = baseSessionAllowance(plan, enrollment, month, legacy);
  const rollover = enrollment?.rolloverMonth === month
    ? Math.max(0, Math.trunc(Number(enrollment.rolloverSessions) || 0))
    : 0;
  const booked = bookingsTowardLimit(bookings, enrollment?.planId || plan.id, month);
  const fromBase = Math.max(0, booked - rollover);
  return Math.max(0, base - fromBase);
}

function sessionLimited(plan, enrollment, legacy) {
  const raw = Number(plan?.maxSessions ?? plan?.data?.maxSessions ?? 0);
  if (Number.isFinite(raw) && raw > 0) return true;
  if (enrollment?.maxSessionsOverride != null && enrollment.maxSessionsOverride !== "") return true;
  return !!(legacy?.applies && legacy.value != null);
}

/// Writes the held sessions onto every active membership entry.
///
/// [window] is { month, frozenFrom, heldFrom, heldUntil }: the month the
/// freeze starts in, the first frozen day, the end day, and the next
/// billing day on or after the end day.
export function applyFreezeHolds(plans, planById, bookings, window, legacyFor) {
  let changed = false;
  const next = (plans || []).map((entry) => {
    if (!entry?.planId || entry.status !== "active") return entry;
    const plan = planById.get(entry.planId) || planById.get(String(entry.planId));
    if (!plan || planKind(plan) !== "membership") return entry;
    const legacy = legacyFor ? legacyFor(entry.planId) : null;
    // A membership with no session count is unlimited. Nothing to hold, and
    // writing 0 would cap it.
    if (!sessionLimited(plan, entry, legacy)) return entry;
    const held = heldSessionsFor(plan, entry, bookings, window.month, legacy);
    changed = true;
    return {
      ...entry,
      heldSessions: held,
      frozenFrom: window.frozenFrom,
      heldFrom: window.heldFrom,
      heldUntil: window.heldUntil,
    };
  });
  return { plans: next, changed };
}

/// After an early unfreeze, or a changed end day, the held sessions start
/// on the new end day and last until the next billing day after it.
export function moveFreezeHolds(plans, heldFrom, heldUntil) {
  let changed = false;
  const next = (plans || []).map((entry) => {
    if (!entry || entry.heldFrom == null) return entry;
    changed = true;
    return { ...entry, heldFrom, heldUntil };
  });
  return { plans: next, changed };
}

/// Drops the hold from every entry. Used when a freeze is cancelled before
/// it started.
export function clearFreezeHolds(plans) {
  let changed = false;
  const next = (plans || []).map((entry) => {
    if (!entry || (entry.heldSessions == null && entry.heldFrom == null && entry.frozenFrom == null)) return entry;
    changed = true;
    const copy = { ...entry };
    delete copy.heldSessions;
    delete copy.frozenFrom;
    delete copy.heldFrom;
    delete copy.heldUntil;
    return copy;
  });
  return { plans: next, changed };
}

function monthBounds(month) {
  const [y, m] = String(month).split("-").map(Number);
  const first = `${month}-01`;
  const next = new Date(Date.UTC(y, m, 1));
  const after = `${next.getUTCFullYear()}-${String(next.getUTCMonth() + 1).padStart(2, "0")}-01`;
  return { first, after };
}

function overlaps(from, until, month) {
  if (!isIsoDay(from)) return false;
  const { first, after } = monthBounds(month);
  const end = isIsoDay(until) ? until : "9999-12-31";
  return from < after && end > first;
}

/// True when any day of [month] was frozen, or was covered by sessions
/// held from a freeze. No sessions roll over from such a month: the client
/// either was not paying for it or already has those sessions held.
///
/// [client] carries the freeze on the client row (membership_paused_at and
/// membership_freeze_ends_at). [enrollment] carries the last freeze's
/// frozenFrom and heldUntil.
export function monthTouchedByFreeze(month, enrollment, client) {
  if (enrollment && overlaps(enrollment.frozenFrom, enrollment.heldUntil ?? enrollment.heldFrom, month)) return true;
  const paused = client?.membership_paused === true || client?.membershipPaused === true;
  const from = client?.membership_paused_at ?? client?.membershipPausedAt ?? null;
  const until = client?.membership_freeze_ends_at ?? client?.membershipFreezeEndsAt ?? null;
  if (paused && !isIsoDay(from)) return true;
  if (isIsoDay(from) && overlaps(from, until, month)) return true;
  return false;
}

/// Whole days between two "YYYY-MM-DD" days, never negative.
export function daysBetween(fromDay, toDay) {
  if (!isIsoDay(fromDay) || !isIsoDay(toDay)) return 0;
  const a = Date.UTC(...fromDay.split("-").map((v, i) => (i === 1 ? Number(v) - 1 : Number(v))));
  const b = Date.UTC(...toDay.split("-").map((v, i) => (i === 1 ? Number(v) - 1 : Number(v))));
  return Math.max(0, Math.round((b - a) / 86400000));
}
