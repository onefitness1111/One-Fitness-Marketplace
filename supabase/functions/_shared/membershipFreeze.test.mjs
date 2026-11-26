import assert from "node:assert/strict";
import test from "node:test";
import {
  applyFreezeHolds,
  clearFreezeHolds,
  daysBetween,
  freezeCovers,
  freezeResumesAt,
  freezeStartsLater,
  heldSessionsFor,
  monthTouchedByFreeze,
  moveFreezeHolds,
  nextBillingOnOrAfter,
  shortDay,
} from "./membershipFreeze.mjs";

const ten = { id: "ten", kind: "membership", maxSessions: 10, rollover: { enabled: true, maxVisits: 4 } };
const pack = { id: "pack", kind: "package", maxSessions: 5 };

function booking(date, extra = {}) {
  return { plan_id: "ten", date, attendance_status: "checked-in", cancelled_at: null, ...extra };
}

test("C4: Stripe resumes one hour before midnight Pacific on the end day", () => {
  // Dec 21 2026 00:00 PST = 08:00 UTC. One hour earlier is 07:00 UTC.
  assert.equal(freezeResumesAt("2026-12-21"), Date.UTC(2026, 11, 21, 7, 0, 0) / 1000);
  // Summer: Jul 21 00:00 PDT = 07:00 UTC, so 06:00 UTC.
  assert.equal(freezeResumesAt("2026-07-21"), Date.UTC(2026, 6, 21, 6, 0, 0) / 1000);
  // The old 12:00 UTC value was after a midnight-Pacific renewal on the end day.
  assert.ok(freezeResumesAt("2026-12-21") < Date.UTC(2026, 11, 21, 8, 0, 0) / 1000);
});

test("C3: a start day after today is scheduled, today or earlier starts now", () => {
  assert.equal(freezeStartsLater("2026-12-01", "2026-11-25"), true);
  assert.equal(freezeStartsLater("2026-11-25", "2026-11-25"), false);
  assert.equal(freezeStartsLater("2026-11-20", "2026-11-25"), false);
});

test("the freeze covers its start day and stops before its end day", () => {
  assert.equal(freezeCovers("2026-12-01", "2026-12-22", "2026-11-30"), false);
  assert.equal(freezeCovers("2026-12-01", "2026-12-22", "2026-12-01"), true);
  assert.equal(freezeCovers("2026-12-01", "2026-12-22", "2026-12-21"), true);
  assert.equal(freezeCovers("2026-12-01", "2026-12-22", "2026-12-22"), false);
  assert.equal(freezeCovers(null, null, "2026-12-22"), true);
});

test("the next billing day on or after the end day", () => {
  assert.equal(nextBillingOnOrAfter("2026-12-10", 21), "2026-12-21");
  assert.equal(nextBillingOnOrAfter("2026-12-21", 21), "2026-12-21");
  assert.equal(nextBillingOnOrAfter("2026-12-22", 21), "2027-01-21");
  assert.equal(nextBillingOnOrAfter("2026-12-22", 31), "2026-12-28");
  // No billing day on file: one month.
  assert.equal(nextBillingOnOrAfter("2026-01-31", null), "2026-02-28");
});

test("held sessions are this month's unused base sessions, never rollover", () => {
  const enrollment = { planId: "ten", status: "active", startDate: "2026-01-01", rolloverSessions: 3, rolloverMonth: "2026-11" };
  // 4 bookings, 3 of them come out of the rollover first.
  const bookings = [booking("2026-11-02"), booking("2026-11-03"), booking("2026-11-04"), booking("2026-11-05")];
  assert.equal(heldSessionsFor(ten, enrollment, bookings, "2026-11", null), 9);
  // Cancels, early/late cancels and other months do not count.
  const more = [
    ...bookings,
    booking("2026-11-06", { cancelled_at: "2026-11-01T00:00:00Z" }),
    booking("2026-11-07", { attendance_status: "late-cancel" }),
    booking("2026-10-30"),
  ];
  assert.equal(heldSessionsFor(ten, enrollment, more, "2026-11", null), 9);
  // A package is never held.
  assert.equal(heldSessionsFor(pack, { planId: "pack", status: "active" }, [], "2026-11", null), 0);
});

test("applyFreezeHolds writes the hold onto active memberships only", () => {
  const plans = [
    { planId: "ten", status: "active", startDate: "2026-01-01" },
    { planId: "pack", status: "active", startDate: "2026-01-01" },
    { planId: "old", status: "cancelled", startDate: "2025-01-01" },
  ];
  const planById = new Map([["ten", ten], ["pack", pack]]);
  const { plans: next, changed } = applyFreezeHolds(plans, planById, [booking("2026-11-02")], {
    month: "2026-11", frozenFrom: "2026-11-05", heldFrom: "2026-12-10", heldUntil: "2026-12-21",
  });
  assert.equal(changed, true);
  assert.deepEqual(next[0], {
    planId: "ten", status: "active", startDate: "2026-01-01",
    heldSessions: 9, frozenFrom: "2026-11-05", heldFrom: "2026-12-10", heldUntil: "2026-12-21",
  });
  assert.deepEqual(next[1], plans[1]);
  assert.deepEqual(next[2], plans[2]);
  // An unlimited membership gets no hold, so it is not capped at 0.
  const unlimited = { id: "unl", kind: "membership" };
  const open = applyFreezeHolds([{ planId: "unl", status: "active" }], new Map([["unl", unlimited]]), [], {
    month: "2026-11", frozenFrom: "2026-11-05", heldFrom: "2026-12-10", heldUntil: "2026-12-21",
  });
  assert.deepEqual(open.plans[0], { planId: "unl", status: "active" });
});

test("an early unfreeze moves the hold, a cancelled schedule clears it", () => {
  const plans = [{ planId: "ten", status: "active", heldSessions: 4, frozenFrom: "2026-11-05", heldFrom: "2026-12-10", heldUntil: "2026-12-21" }];
  assert.deepEqual(moveFreezeHolds(plans, "2026-11-20", "2026-11-21").plans[0], {
    planId: "ten", status: "active", heldSessions: 4, frozenFrom: "2026-11-05", heldFrom: "2026-11-20", heldUntil: "2026-11-21",
  });
  assert.deepEqual(clearFreezeHolds(plans).plans[0], { planId: "ten", status: "active" });
});

test("L6: no rollover from a month that was frozen or covered by held sessions", () => {
  const enrollment = { frozenFrom: "2026-11-05", heldFrom: "2026-12-10", heldUntil: "2026-12-21" };
  assert.equal(monthTouchedByFreeze("2026-10", enrollment, null), false);
  assert.equal(monthTouchedByFreeze("2026-11", enrollment, null), true);
  assert.equal(monthTouchedByFreeze("2026-12", enrollment, null), true);
  assert.equal(monthTouchedByFreeze("2027-01", enrollment, null), false);
  // A freeze still on the client row counts too.
  const client = { membership_paused: true, membership_paused_at: "2026-10-28", membership_freeze_ends_at: "2026-11-02" };
  assert.equal(monthTouchedByFreeze("2026-10", {}, client), true);
  assert.equal(monthTouchedByFreeze("2026-11", {}, client), true);
  assert.equal(monthTouchedByFreeze("2026-12", {}, client), false);
  // A freeze that ends on the 1st does not touch that month.
  const endsFirst = { membership_paused: true, membership_paused_at: "2026-10-10", membership_freeze_ends_at: "2026-11-01" };
  assert.equal(monthTouchedByFreeze("2026-11", {}, endsFirst), false);
});

test("helpers", () => {
  assert.equal(shortDay("2026-12-22"), "Dec 22");
  assert.equal(daysBetween("2026-11-05", "2026-12-10"), 35);
  assert.equal(daysBetween("2026-12-10", "2026-11-05"), 0);
});
