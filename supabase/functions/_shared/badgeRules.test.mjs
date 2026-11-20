import assert from "node:assert/strict";
import test from "node:test";
import {
  FOOD_LOG_TABLE,
  addDays,
  championQualifies,
  foodLogDates,
  goalReachedQualifies,
  habitQualifies,
  isForceAward,
  lastPacificMonth,
  mayRevoke,
  monthWindowQualifies,
  nutritionStreakQualifies,
  oneYearQualifies,
  packageWindowQualifies,
  pacificToday,
  bundleKeys,
  perfectAttendanceQualifies,
  sessionMilestoneHits,
  timeWindowQualifies,
  weeklyScore,
  TIME_WINDOWS,
} from "./badgeRules.mjs";

const early = TIME_WINDOWS.early_bird;
const day = TIME_WINDOWS.daytimer;
const night = TIME_WINDOWS.night_owl;

function sessions(n, slotMin, date = "2026-10-10") {
  return Array.from({ length: n }, () => ({ date, slotMin }));
}

test("Pacific month boundary is not UTC", () => {
  // 06:30 UTC on Nov 1 2026 is still Oct 31 in Pacific (PDT, UTC-7).
  // A UTC clock already calls that instant November, so it would score
  // October a few hours before October had ended.
  const now = new Date("2026-11-01T06:30:00Z");
  assert.equal(pacificToday(now), "2026-10-31");
  assert.equal(lastPacificMonth(now), "2026-09");
  // After midnight Pacific, last month is October.
  const later = new Date("2026-11-01T07:30:00Z");
  assert.equal(pacificToday(later), "2026-11-01");
  assert.equal(lastPacificMonth(later), "2026-10");
});

test("membership quota must be filled, all in the window", () => {
  assert.equal(monthWindowQualifies({ cap: 4, sessions: sessions(4, 8 * 60), windowFn: early }), true);
  assert.equal(monthWindowQualifies({ cap: 4, sessions: sessions(3, 8 * 60), windowFn: early }), false);
  assert.equal(monthWindowQualifies({ cap: 4, sessions: [...sessions(3, 8 * 60), { slotMin: 10 * 60 }], windowFn: early }), false);
  assert.equal(monthWindowQualifies({ cap: 4, sessions: [], windowFn: early }), false);
});

test("no session cap means every completed session last month, and at least one", () => {
  assert.equal(monthWindowQualifies({ cap: null, sessions: sessions(3, 19 * 60), windowFn: night }), true);
  assert.equal(monthWindowQualifies({ cap: 0, sessions: sessions(2, 12 * 60), windowFn: day }), true);
  assert.equal(monthWindowQualifies({ cap: null, sessions: [...sessions(2, 19 * 60), { slotMin: 8 * 60 }], windowFn: night }), false);
  assert.equal(monthWindowQualifies({ cap: null, sessions: [], windowFn: night }), false);
});

test("a package is earned when its last session is completed, all in one window", () => {
  assert.equal(packageWindowQualifies({ cap: 8, sessions: sessions(8, 7 * 60), windowFn: early }), true);
  assert.equal(packageWindowQualifies({ cap: 8, sessions: sessions(7, 7 * 60), windowFn: early }), false);
  assert.equal(packageWindowQualifies({ cap: 8, sessions: [...sessions(7, 7 * 60), { slotMin: 14 * 60 }], windowFn: early }), false);
  const decision = timeWindowQualifies({
    planKind: "package",
    cap: 8,
    packageSessions: sessions(8, 7 * 60),
    monthSessions: [],
    windowFn: early,
  });
  assert.equal(decision.qualifies, true);
  assert.equal(decision.sticky, true);
});

test("the old membership-only rule is what blocked package clients", () => {
  const decision = timeWindowQualifies({
    planKind: "package",
    cap: 4,
    packageSessions: sessions(4, 400),
    monthSessions: sessions(4, 400),
    windowFn: early,
  });
  assert.equal(decision.qualifies, true);
  const unlimited = timeWindowQualifies({
    planKind: "membership",
    cap: null,
    packageSessions: [],
    monthSessions: sessions(5, 400),
    windowFn: early,
  });
  assert.equal(unlimited.qualifies, true);
  assert.equal(unlimited.sticky, false);
});

test("windows are early, midday, and evening", () => {
  assert.equal(early(8 * 60 + 59), true);
  assert.equal(early(9 * 60), false);
  assert.equal(day(9 * 60), true);
  assert.equal(day(18 * 60 - 1), true);
  assert.equal(day(18 * 60), false);
  assert.equal(night(18 * 60), true);
});

test("habit streak uses calendar days, not a UTC shift", () => {
  const ids = ["water", "sleep"];
  const today = "2026-11-18";
  const logs = [];
  for (let i = 0; i < 21; i++) {
    logs.push({ date: addDays(today, -i), checked: { water: true, sleep: true } });
  }
  const record = { habitSettings: { enabled: ids, custom: [] }, habitLogs: logs };
  assert.equal(habitQualifies(record, { todayYmd: today, percent: 80, weeks: 3 }), true);
  assert.equal(weeklyScore(record, ids, today), 100);
  // Six days at exactly 80%, plus the empty next day a UTC clock would
  // include, drops under the bar. Scoring the Pacific day does not.
  const ids5 = ["water", "sleep", "meal", "supps", "workout"];
  const exact = [];
  for (let i = 0; i < 7; i++) {
    exact.push({ date: addDays(today, -i), checked: { water: true, sleep: true, meal: true, supps: true } });
  }
  const exactRecord = { habitSettings: { enabled: ids5, custom: [] }, habitLogs: exact };
  assert.equal(weeklyScore(exactRecord, ids5, today), 80);
  assert.ok(weeklyScore(exactRecord, ids5, addDays(today, 1)) < 80);
  assert.equal(habitQualifies(exactRecord, { todayYmd: today, percent: 80, weeks: 1 }), true);
});

test("session milestones and the first session", () => {
  assert.deepEqual(sessionMilestoneHits(0), []);
  const one = sessionMilestoneHits(1);
  const ten = sessionMilestoneHits(10);
  assert.deepEqual(one, []);
  assert.deepEqual(ten, ["sessions_10"]);
  assert.equal(one.includes("first_session"), false);
  assert.equal(ten.includes("first_session"), false);
  assert.equal(bundleKeys("after_session").includes("first_session"), false);
  assert.ok(sessionMilestoneHits(100).includes("sessions_100"));
});

test("one year is 365 days after they joined", () => {
  assert.equal(oneYearQualifies("2025-11-18", "2026-11-18"), true);
  assert.equal(oneYearQualifies("2025-11-19", "2026-11-18"), false);
});

test("nutrition streak reads the food log dates", () => {
  assert.equal(FOOD_LOG_TABLE, "client_records");
  const today = "2026-11-18";
  const days = {};
  for (let i = 0; i < 7; i++) days[addDays(today, -i)] = { breakfast: [{ name: "oats" }] };
  const dates = foodLogDates({ days });
  assert.equal(nutritionStreakQualifies(dates, today), true);
  delete days[addDays(today, -3)];
  assert.equal(nutritionStreakQualifies(foodLogDates({ days }), today), false);
  // Yesterday's finished week still counts on a morning they have not logged yet.
  const prior = {};
  for (let i = 1; i <= 7; i++) prior[addDays(today, -i)] = { lunch: [{ name: "rice" }] };
  assert.equal(nutritionStreakQualifies(foodLogDates({ days: prior }), today), true);
});

test("perfect attendance ignores early cancels and fails a miss", () => {
  assert.equal(perfectAttendanceQualifies([
    { attendance: "checked-in" },
    { attendance: "early-cancel" },
  ]), true);
  assert.equal(perfectAttendanceQualifies([
    { attendance: "checked-in" },
    { attendance: "no-show" },
  ]), false);
  assert.equal(perfectAttendanceQualifies([]), false);
  assert.equal(perfectAttendanceQualifies([{ attendance: "checked-in", cancelled: true }]), false);
});

test("goal reached is weight within half a pound, or an inch off a measurement", () => {
  assert.equal(goalReachedQualifies({
    measurements: [{ date: "2026-10-01", weight: "180 lbs" }, { date: "2026-11-01", weight: "170.4" }],
    goalWeight: 170,
  }), true);
  assert.equal(goalReachedQualifies({
    measurements: [{ date: "2026-10-01", weight: "180" }],
    goalWeight: 170,
  }), false);
  assert.equal(goalReachedQualifies({
    measurements: [
      { date: "2026-10-01", waist: "34 in" },
      { date: "2026-11-01", waist: "32.5" },
    ],
    goalWeight: null,
  }), true);
});

test("champion follows a coach's pick, otherwise first place", () => {
  assert.equal(championQualifies({ ended: true, winnerId: "a", clientId: "a", rank: 2 }), true);
  assert.equal(championQualifies({ ended: true, winnerId: "a", clientId: "b", rank: 1 }), false);
  assert.equal(championQualifies({ ended: true, winnerId: null, clientId: "b", rank: 1 }), true);
  assert.equal(championQualifies({ ended: false, winnerId: "a", clientId: "a", rank: 1 }), false);
});

test("a badge the owner force-assigns is not revoked", () => {
  assert.equal(isForceAward("force"), true);
  assert.equal(mayRevoke("force", "early_bird"), false);
  assert.equal(mayRevoke("automatic", "early_bird"), true);
  assert.equal(mayRevoke("automatic", "champion"), false);
  assert.equal(mayRevoke("automatic", "sessions_25"), false);
});
