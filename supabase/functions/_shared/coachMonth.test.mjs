import assert from "node:assert/strict";
import test from "node:test";
import {
  clientMilestoneAwards,
  fullHouseQualifies,
  prFactoryQualifies,
  retentionQualifies,
  sessionsCoachedQualifies,
} from "./coachMonth.mjs";

const month = { start: "2026-10-01", end: "2026-10-31" };

test("20 checked-in sessions in the month", () => {
  const bookings = Array.from({ length: 20 }, (_, i) => ({
    date: `2026-10-${String((i % 28) + 1).padStart(2, "0")}`,
    attendance: "checked-in",
  }));
  assert.equal(sessionsCoachedQualifies(bookings, month.start, month.end), true);
  assert.equal(sessionsCoachedQualifies(bookings.slice(0, 19), month.start, month.end), false);
});

test("retention is one client present in each of the last 3 months", () => {
  const bookings = ["2026-08-02", "2026-09-04", "2026-10-06"].map((date) => ({
    clientId: "a",
    date,
    attendance: "checked-in",
  }));
  assert.equal(retentionQualifies(bookings, "2026-10"), true);
  assert.equal(retentionQualifies(bookings.filter((b) => !b.date.startsWith("2026-09")), "2026-10"), false);
});

test("a client milestone is credited to the coach of the crossing session", () => {
  const bookings = [];
  for (let i = 1; i <= 10; i++) {
    bookings.push({
      clientId: "a",
      trainerId: i === 10 ? "coach-b" : "coach-a",
      date: `2026-10-${String(i).padStart(2, "0")}`,
      slotMin: 600,
      attendance: "checked-in",
    });
  }
  const awards = clientMilestoneAwards(bookings, { start: month.start, end: month.end });
  assert.equal(awards.length, 1);
  assert.equal(awards[0].trainerId, "coach-b");
  assert.equal(awards[0].count, 10);
  assert.equal(awards[0].badgeKey, "client_milestone_a_10");
});

test("full house needs both the check-in rate and the booked capacity", () => {
  const availability = [{ sessionType: "one-on-one", discipline: "personal-training", byDay: { 1: [540] } }];
  // October 2026: Mondays are 5, 12, 19, 26. Four one-on-one slots, cap 1 each.
  const bookings = [5, 12, 19, 26].map((d) => ({
    date: `2026-10-${String(d).padStart(2, "0")}`,
    attendance: "checked-in",
  }));
  assert.equal(fullHouseQualifies({ availability, unavailability: [], bookings, ...month }), true);
  const missed = bookings.map((b, i) => (i === 0 ? { ...b, attendance: "no-show" } : b));
  assert.equal(fullHouseQualifies({ availability, unavailability: [], bookings: missed, ...month }), false);
});

test("a partial-day block only removes the slots it covers", () => {
  const availability = [{ sessionType: "one-on-one", discipline: "personal-training", byDay: { 1: [540, 900] }, durationMin: 60 }];
  // October 2026 Mondays: 5, 12, 19, 26. Four morning bookings, all checked in.
  const bookings = [5, 12, 19, 26].map((d) => ({
    date: `2026-10-${String(d).padStart(2, "0")}`,
    attendance: "checked-in",
  }));
  // Afternoon-only block leaves the 9:00 slots. 4 booked / 4 open = full house.
  const afternoon = [{ startDate: "2026-10-01", endDate: "2026-10-31", allDay: false, startMin: 840, endMin: 24 * 60 }];
  assert.equal(fullHouseQualifies({ availability, unavailability: afternoon, bookings, ...month }), true);
  // The same dates with no times is a legacy all-day block, so those mornings are gone.
  const legacy = [{ startDate: "2026-10-01", endDate: "2026-10-31", note: "Away" }];
  assert.equal(fullHouseQualifies({ availability, unavailability: legacy, bookings, ...month }), false);
});

test("PR factory is five different clients", () => {
  const events = ["a", "b", "c", "d", "e"].map((clientId) => ({ clientId, earnedAt: "2026-10-03T12:00:00Z" }));
  assert.equal(prFactoryQualifies(events, month.start, month.end), true);
  assert.equal(prFactoryQualifies(events.slice(0, 4), month.start, month.end), false);
});
