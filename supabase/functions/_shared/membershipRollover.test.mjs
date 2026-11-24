import assert from "node:assert/strict";
import test from "node:test";
import {
  applyMonthEndEnrollment,
  applyMonthEndPlans,
  clearPlanOverrides,
  clientIsActiveOnPlan,
  consumedSessions,
  freshEnrollment,
  nextPlanEnrollments,
  pacificCalendar,
  previousMonth,
  rolloverCap,
  sessionAllowance,
} from "./membershipRollover.mjs";

const ten = {
  id: "ten",
  kind: "membership",
  maxSessions: 10,
  rollover: { enabled: true, maxVisits: 4 },
};
const sixteen = {
  id: "sixteen",
  kind: "membership",
  maxSessions: 16,
  rollover: { enabled: true, maxVisits: 4 },
};

function enrol(planId, extra = {}) {
  return { planId, status: "active", startDate: "2026-06-01", ...extra };
}

test("an override on one plan does not change the other", () => {
  const onTen = enrol("ten", { maxSessionsOverride: 19, maxSessionsOverrideMonth: "2026-11" });
  const onSixteen = enrol("sixteen");
  assert.equal(sessionAllowance(ten, onTen, "2026-11", null), 19);
  assert.equal(sessionAllowance(sixteen, onSixteen, "2026-11", null), 16);
});

test("a legacy override counts only for the plan in the slot", () => {
  const legacy = { applies: true, value: 19, month: "2026-11" };
  const notThisPlan = { applies: false, value: 19, month: "2026-11" };
  assert.equal(sessionAllowance(sixteen, enrol("sixteen"), "2026-11", legacy), 19);
  assert.equal(sessionAllowance(ten, enrol("ten"), "2026-11", notThisPlan), 10);
  assert.equal(
    sessionAllowance(sixteen, enrol("sixteen", { maxSessionsOverride: 8, maxSessionsOverrideMonth: "2026-11" }), "2026-11", legacy),
    8,
  );
});

test("a membership override from another month falls back to the plan", () => {
  const entry = enrol("ten", { maxSessionsOverride: 19, maxSessionsOverrideMonth: "2026-10" });
  assert.equal(sessionAllowance(ten, entry, "2026-11", null), 10);
});

test("rolled sessions add for that month only", () => {
  const entry = enrol("ten", { rolloverSessions: 3, rolloverMonth: "2026-11" });
  assert.equal(sessionAllowance(ten, entry, "2026-11", null), 13);
  assert.equal(sessionAllowance(ten, entry, "2026-12", null), 10);
});

test("rollover cap: 0 means none, blank uses the membership, off means none", () => {
  assert.equal(rolloverCap(ten, enrol("ten", { rolloverMaxOverride: 0 })), 0);
  assert.equal(rolloverCap(ten, enrol("ten")), 4);
  assert.equal(rolloverCap({ ...ten, rollover: { enabled: false, maxVisits: 4 } }, enrol("ten")), 0);
  assert.equal(rolloverCap({ id: "pack", kind: "package", maxSessions: 8 }, enrol("pack")), 0);
});

test("month end caps unused sessions and ignores other plans", () => {
  const entry = enrol("ten", { rolloverSessions: 4, rolloverMonth: "2026-10" });
  const bookings = [
    { planId: "ten", date: "2026-10-02", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-10-03", attendanceStatus: "no-show" },
    { planId: "ten", date: "2026-10-04", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-10-05" },
    { planId: "ten", date: "2026-10-06", attendanceStatus: "early-cancel" },
    { planId: "ten", date: "2026-10-07", attendanceStatus: "checked-in", cancelled_at: "2026-10-07" },
    { planId: "sixteen", date: "2026-10-02", attendanceStatus: "checked-in" },
  ];
  assert.equal(consumedSessions(bookings, "ten", "2026-10"), 3);
  const rolled = applyMonthEndEnrollment(ten, entry, bookings, "2026-11", null);
  assert.equal(rolled.changed, true);
  assert.equal(rolled.enrollment.rolloverSessions, 4);
  assert.equal(rolled.enrollment.rolloverMonth, "2026-11");
  assert.equal(rolled.enrollment.maxSessionsOverride, undefined);
});

test("rollover does not compound and a second run is a no-op", () => {
  const first = applyMonthEndEnrollment(ten, enrol("ten"), [], "2026-11", null);
  assert.equal(first.enrollment.rolloverSessions, 4);
  const second = applyMonthEndEnrollment(ten, first.enrollment, [], "2026-11", null);
  assert.equal(second.changed, false);
  assert.equal(second.enrollment.rolloverSessions, 4);

  // November's own 10 were unused, so 4 of those (the cap) roll into
  // December. The 4 already sitting in November are not in this count.
  const december = applyMonthEndEnrollment(
    ten,
    enrol("ten", { rolloverSessions: 4, rolloverMonth: "2026-11" }),
    [],
    "2026-12",
    null,
  );
  assert.equal(december.enrollment.rolloverSessions, 4);
  assert.equal(december.enrollment.rolloverMonth, "2026-12");
});

test("rolled sessions expire after one month and are not rolled again", () => {
  const usedAllBase = [
    { planId: "ten", date: "2026-11-02", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-03", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-04", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-05", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-06", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-07", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-08", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-09", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-10", attendanceStatus: "checked-in" },
    { planId: "ten", date: "2026-11-11", attendanceStatus: "checked-in" },
  ];
  // November was 10 + 4 rolled in, and all 10 of the base were used. The
  // leftover 4 expire; December gets none.
  const spent = applyMonthEndEnrollment(
    ten,
    enrol("ten", { rolloverSessions: 4, rolloverMonth: "2026-11" }),
    usedAllBase,
    "2026-12",
    null,
  );
  assert.equal(spent.changed, true);
  assert.equal(spent.enrollment.rolloverSessions, 0);
  assert.equal(spent.enrollment.rolloverMonth, "2026-12");

  // Eight of the base 10 were used, so 2 of November's own unused sessions
  // roll (under the cap of 4). The leftover rolled-in 4 still expire.
  const usedEight = usedAllBase.slice(0, 8);
  const leftover = applyMonthEndEnrollment(
    ten,
    enrol("ten", { rolloverSessions: 4, rolloverMonth: "2026-11" }),
    usedEight,
    "2026-12",
    null,
  );
  assert.equal(leftover.enrollment.rolloverSessions, 2);
  assert.equal(leftover.enrollment.rolloverMonth, "2026-12");
});

test("a new member and an ended plan are left alone", () => {
  const joined = applyMonthEndEnrollment(ten, enrol("ten", { startDate: "2026-11-03" }), [], "2026-11", null);
  assert.equal(joined.changed, false);
  const ended = applyMonthEndEnrollment(ten, enrol("ten", { endsAt: "2026-10-20" }), [], "2026-11", null);
  assert.equal(ended.changed, false);
});

test("a custom cap is what the job uses, including zero", () => {
  const two = applyMonthEndEnrollment(ten, enrol("ten", { rolloverMaxOverride: 2 }), [], "2026-11", null);
  assert.equal(two.enrollment.rolloverSessions, 2);
  const none = applyMonthEndEnrollment(ten, enrol("ten", { rolloverMaxOverride: 0 }), [], "2026-11", null);
  assert.equal(none.enrollment.rolloverSessions, 0);
  assert.equal(none.enrollment.rolloverMonth, "2026-11");
  const again = applyMonthEndEnrollment(ten, none.enrollment, [], "2026-11", null);
  assert.equal(again.changed, false);
});

test("apply to everyone clears one plan and leaves the other", () => {
  const plans = [
    enrol("ten", { maxSessionsOverride: 19, maxSessionsOverrideMonth: "2026-11", rolloverMaxOverride: 2, rolloverSessions: 3, rolloverMonth: "2026-11" }),
    enrol("sixteen", { maxSessionsOverride: 12, rolloverMaxOverride: 1 }),
  ];
  const cleared = clearPlanOverrides(plans, "ten");
  assert.equal(cleared[0].maxSessionsOverride, undefined);
  assert.equal(cleared[0].rolloverMaxOverride, undefined);
  assert.equal(cleared[0].rolloverSessions, 3);
  assert.equal(cleared[1].maxSessionsOverride, 12);
  assert.equal(cleared[1].rolloverMaxOverride, 1);
  assert.equal(clientIsActiveOnPlan({ membershipPlanId: "ten", plans }, "ten"), true);
  assert.equal(clientIsActiveOnPlan({ membershipPlanId: "other", plans: [enrol("sixteen")] }, "ten"), false);
});

test("the job rolls each active membership and skips one already done", () => {
  const plans = [
    enrol("ten"),
    enrol("sixteen", { rolloverMonth: "2026-11", rolloverSessions: 1 }),
  ];
  const byId = new Map([["ten", ten], ["sixteen", sixteen]]);
  const first = applyMonthEndPlans(plans, byId, [], "2026-11", () => null);
  assert.equal(first.changed, true);
  assert.equal(first.plans[0].rolloverSessions, 4);
  assert.equal(first.plans[1].rolloverSessions, 1);
  const second = applyMonthEndPlans(first.plans, byId, [], "2026-11", () => null);
  assert.equal(second.changed, false);
});

test("a new or renewed plan starts clean and the old override stays on the old plan", () => {
  const existing = [
    enrol("sixteen", { maxSessionsOverride: 19, maxSessionsOverrideMonth: "2026-10" }),
  ];
  const added = nextPlanEnrollments({
    plans: existing,
    membershipPlanId: "sixteen",
    sessionCountOverride: 19,
    sessionCountOverrideMonth: "2026-10",
    planId: "ten",
    today: "2026-11-22",
    termMonths: null,
  });
  assert.equal(added.clearLegacy, true);
  const kept = added.plans.find((e) => e.planId === "sixteen");
  const fresh = added.plans.find((e) => e.planId === "ten");
  assert.equal(kept.maxSessionsOverride, 19);
  assert.equal(fresh.maxSessionsOverride, undefined);
  assert.equal(fresh.rolloverMaxOverride, undefined);
  assert.equal(fresh.rolloverSessions, undefined);
  assert.equal(fresh.startDate, "2026-11-22");
  assert.deepEqual(freshEnrollment({ planId: "ten", today: "2026-11-22" }).rolloverMonth, undefined);
});

test("a legacy column is moved onto the old plan, not the plan being added", () => {
  const added = nextPlanEnrollments({
    plans: [enrol("sixteen")],
    membershipPlanId: "sixteen",
    sessionCountOverride: 19,
    sessionCountOverrideMonth: "2026-10",
    planId: "ten",
    today: "2026-11-22",
  });
  const kept = added.plans.find((e) => e.planId === "sixteen");
  const fresh = added.plans.find((e) => e.planId === "ten");
  assert.equal(kept.maxSessionsOverride, 19);
  assert.equal(kept.maxSessionsOverrideMonth, "2026-10");
  assert.equal(fresh.maxSessionsOverride, undefined);
  assert.equal(fresh.rolloverSessions, undefined);
});

test("renewing the same plan does not keep its old override", () => {
  const renewed = nextPlanEnrollments({
    plans: [enrol("ten", { maxSessionsOverride: 19, rolloverMaxOverride: 2, rolloverSessions: 4, rolloverMonth: "2026-10" })],
    membershipPlanId: "ten",
    sessionCountOverride: 19,
    sessionCountOverrideMonth: "2026-10",
    planId: "ten",
    today: "2026-11-22",
  });
  assert.equal(renewed.plans.length, 1);
  assert.equal(renewed.plans[0].maxSessionsOverride, undefined);
  assert.equal(renewed.plans[0].rolloverMaxOverride, undefined);
  assert.equal(renewed.plans[0].rolloverSessions, undefined);
  assert.equal(renewed.clearLegacy, true);
});

test("Pacific month boundary is not UTC", () => {
  // 06:30 UTC on Nov 1 2026 is still Oct 31 in Pacific (PDT, UTC-7).
  const before = pacificCalendar(new Date("2026-11-01T06:30:00Z"));
  assert.equal(before.date, "2026-10-31");
  assert.equal(before.day, 31);
  assert.equal(before.month, "2026-10");
  const onTheFirst = pacificCalendar(new Date("2026-11-01T08:00:00Z"));
  assert.equal(onTheFirst.day, 1);
  assert.equal(onTheFirst.month, "2026-11");
  assert.equal(previousMonth("2026-01"), "2025-12");
});
