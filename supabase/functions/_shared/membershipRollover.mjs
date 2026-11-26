// Per-plan session overrides and month-end membership rollover.
//
// Same rules as lib/core/utils/membership_rollover.dart. The month-end job,
// "apply to everyone", and enroll-free-plan all go through here so a second
// run cannot stack rollover and a new plan cannot inherit another plan's
// override.
//
// stripe-webhook is not in this repo. When it grants a plan it must insert a
// fresh enrollment (see freshEnrollment) and must not copy maxSessionsOverride
// or rolloverMaxOverride from any other plan. The database trigger
// preserve_session_override_on_plan_change keeps a legacy client-level
// override on the plan that was in the slot when the slot changes.

export function previousMonth(yyyyMm) {
  const [y, m] = String(yyyyMm).split("-").map(Number);
  const prev = new Date(Date.UTC(y, m - 2, 1));
  const mm = String(prev.getUTCMonth() + 1).padStart(2, "0");
  return `${prev.getUTCFullYear()}-${mm}`;
}

/// Calendar date in America/Los_Angeles. The month-end job runs on day 1.
export function pacificCalendar(date) {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const parts = Object.fromEntries(fmt.formatToParts(date).map((p) => [p.type, p.value]));
  return {
    day: Number(parts.day),
    month: `${parts.year}-${parts.month}`,
    date: `${parts.year}-${parts.month}-${parts.day}`,
  };
}

function num(value) {
  if (value == null || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

export function planKind(plan) {
  return plan?.kind || plan?.data?.kind || "";
}

function planMaxSessions(plan) {
  const raw = plan?.maxSessions ?? plan?.data?.maxSessions;
  return Math.max(0, num(raw) ?? 0);
}

function planRolloverEnabled(plan) {
  if (typeof plan?.rolloverEnabled === "boolean") return plan.rolloverEnabled;
  if (typeof plan?.rollover?.enabled === "boolean") return plan.rollover.enabled;
  if (typeof plan?.data?.rollover?.enabled === "boolean") return plan.data.rollover.enabled;
  return false;
}

function planRolloverMax(plan) {
  const raw = plan?.rolloverMaxVisits ?? plan?.rollover?.maxVisits ?? plan?.data?.rollover?.maxVisits;
  return Math.max(0, num(raw) ?? 0);
}

export function rolloverCap(plan, enrollment) {
  if (planKind(plan) !== "membership") return 0;
  const custom = num(enrollment?.rolloverMaxOverride);
  if (custom != null) return Math.max(0, custom);
  if (!planRolloverEnabled(plan)) return 0;
  return planRolloverMax(plan);
}

/// Base allowance for one month: the plan count, or this client's override
/// for that month. Sessions already rolled into the month are not included,
/// so a carry-over expires with the month and cannot be rolled again.
/// legacy.applies is true only for the plan that currently occupies the
/// client's membership slot, and only as a fallback when that plan entry
/// has no maxSessionsOverride of its own.
export function baseSessionAllowance(plan, enrollment, month, legacy) {
  let base = planMaxSessions(plan);
  let override = num(enrollment?.maxSessionsOverride);
  let overrideMonth = enrollment?.maxSessionsOverrideMonth || null;
  if (override == null && legacy?.applies) {
    override = num(legacy.value);
    overrideMonth = legacy.month || null;
  }
  if (override != null) {
    const stale = planKind(plan) === "membership" && !!overrideMonth && overrideMonth !== month;
    if (!stale) base = Math.max(0, override);
  }
  return base;
}

/// Allowance for one month: baseSessionAllowance plus sessions already
/// rolled into that month. Use this to show what the client can use now.
/// Month-end rollover uses baseSessionAllowance.
export function sessionAllowance(plan, enrollment, month, legacy) {
  let base = baseSessionAllowance(plan, enrollment, month, legacy);
  if (planKind(plan) === "membership" && enrollment?.rolloverMonth === month) {
    base += Math.max(0, num(enrollment.rolloverSessions) ?? 0);
  }
  return base;
}

const CONSUMED = new Set(["checked-in", "no-show"]);

export function consumedSessions(bookings, planId, month) {
  let n = 0;
  for (const b of bookings || []) {
    const id = b.planId ?? b.plan_id;
    if (id !== planId || String(id).startsWith("single:")) continue;
    if (b.cancelled || b.cancelledAt || b.cancelled_at) continue;
    if (b.status === "cancelled") continue;
    if (b.isPhysicalAssessment || b.is_physical_assessment) continue;
    const attendance = b.attendanceStatus ?? b.attendance_status ?? b.attendance;
    if (!CONSUMED.has(attendance)) continue;
    if (!String(b.date || "").startsWith(month)) continue;
    n += 1;
  }
  return n;
}

/// [frozen] is true when the month being closed was frozen, or covered by
/// sessions held from a freeze (see membershipFreeze.mjs
/// monthTouchedByFreeze). Nothing rolls from such a month, but the entry is
/// still stamped so a second run does not roll it either (L6).
export function applyMonthEndEnrollment(plan, enrollment, bookings, newMonth, legacy, frozen = false) {
  if (!enrollment || planKind(plan) !== "membership") return { enrollment, changed: false };
  if (enrollment.status !== "active") return { enrollment, changed: false };
  if (enrollment.rolloverMonth === newMonth) return { enrollment, changed: false };
  const prev = previousMonth(newMonth);
  const start = String(enrollment.startDate || "").slice(0, 7);
  if (start && start > prev) return { enrollment, changed: false };
  const ends = enrollment.endsAt ? String(enrollment.endsAt).slice(0, 10) : "";
  if (ends && ends < `${newMonth}-01`) return { enrollment, changed: false };
  if (frozen) {
    return {
      enrollment: { ...enrollment, rolloverSessions: 0, rolloverMonth: newMonth },
      changed: true,
    };
  }
  // Unused of this month's own allowance only. Sessions already rolled
  // into prev expire with that month and are not carried again.
  const allowance = baseSessionAllowance(plan, enrollment, prev, legacy);
  const used = consumedSessions(bookings, enrollment.planId || plan.id, prev);
  const unused = Math.max(0, allowance - used);
  const rolled = Math.min(unused, rolloverCap(plan, enrollment));
  return {
    enrollment: { ...enrollment, rolloverSessions: rolled, rolloverMonth: newMonth },
    changed: true,
  };
}

export function applyMonthEndPlans(plans, planById, bookings, newMonth, legacyFor, frozenFor) {
  let changed = false;
  const next = (plans || []).map((entry) => {
    if (!entry?.planId) return entry;
    const plan = planById.get(entry.planId) || planById.get(String(entry.planId));
    if (!plan) return entry;
    const legacy = legacyFor ? legacyFor(entry.planId) : null;
    const frozen = frozenFor ? frozenFor(entry) === true : false;
    const result = applyMonthEndEnrollment(plan, entry, bookings, newMonth, legacy, frozen);
    if (result.changed) changed = true;
    return result.enrollment;
  });
  return { plans: next, changed };
}

export function clearPlanOverrides(plans, planId) {
  return (plans || []).map((entry) => {
    if (!entry || entry.planId !== planId || entry.status !== "active") return entry;
    if (entry.maxSessionsOverride == null && entry.maxSessionsOverrideMonth == null && entry.rolloverMaxOverride == null) {
      return entry;
    }
    const next = { ...entry };
    delete next.maxSessionsOverride;
    delete next.maxSessionsOverrideMonth;
    delete next.rolloverMaxOverride;
    return next;
  });
}

export function clientIsActiveOnPlan(client, planId) {
  if (!client || !planId) return false;
  const slot = client.membershipPlanId ?? client.membership_plan_id;
  if (slot === planId) return true;
  return (client.plans || []).some((entry) => entry && entry.planId === planId && entry.status === "active");
}

export function freshEnrollment({ planId, today, termMonths, endsAt }) {
  const row = { planId, status: "active", startDate: today };
  if (termMonths != null) row.termMonths = termMonths;
  if (endsAt) row.endsAt = String(endsAt);
  return row;
}

/// Put a legacy client-level override onto [planId]'s active entry, if that
/// entry does not already have its own. Does not create a plan the client
/// does not already hold.
export function stampLegacyOverride(plans, planId, override, month) {
  const value = num(override);
  if (!planId || value == null) return { plans: plans || [], stamped: false };
  let stamped = false;
  const next = (plans || []).map((entry) => {
    if (stamped || !entry || entry.planId !== planId || entry.status !== "active") return entry;
    if (entry.maxSessionsOverride != null) {
      stamped = true;
      return entry;
    }
    stamped = true;
    const row = { ...entry, maxSessionsOverride: value };
    if (month) row.maxSessionsOverrideMonth = month;
    return row;
  });
  return { plans: next, stamped };
}

/// The enrollments to store when [planId] is added or renewed.
///
/// The new entry is empty of overrides and rollover. A legacy client-level
/// override is moved onto the plan that was already in the slot, never onto
/// the plan being added. [clearLegacy] tells the caller to null the columns
/// so they cannot follow the client onto the new slot.
export function nextPlanEnrollments({
  plans,
  membershipPlanId,
  sessionCountOverride,
  sessionCountOverrideMonth,
  planId,
  today,
  termMonths,
  endsAt,
}) {
  const kept = (plans || []).filter((entry) => entry?.planId !== planId);
  const legacy = num(sessionCountOverride);
  let relocated = kept;
  if (legacy != null && membershipPlanId && membershipPlanId !== planId) {
    relocated = stampLegacyOverride(kept, membershipPlanId, legacy, sessionCountOverrideMonth || null).plans;
  }
  return {
    plans: [...relocated, freshEnrollment({ planId, today, termMonths, endsAt })],
    clearLegacy: legacy != null,
  };
}
