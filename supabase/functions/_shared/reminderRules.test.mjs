import assert from "node:assert/strict";
import test from "node:test";
import {
  challengeActive,
  challengeClosesInTwoDays,
  challengeParticipants,
  habitReminderDue,
  reminderPlan,
  sessionDayWord,
  sessionReminderDue,
  slotLabel,
} from "./reminderRules.mjs";

// PST: Pacific = UTC-8.
const at = (iso) => new Date(iso);

test("nothing is due at 5am anymore; quiet hours hold everything", () => {
  const plan = reminderPlan(at("2026-11-27T13:00:00Z")); // 5:00am Pacific
  assert.equal(plan.quiet, true);
  assert.equal(plan.sessions, false);
  assert.equal(plan.habits, false);
  assert.equal(plan.drainQueue, false);
  assert.equal(plan.monthly, false);
});

test("habits go out at 7pm Pacific, in winter and summer", () => {
  assert.equal(reminderPlan(at("2026-11-28T03:00:00Z")).habits, true); // 7pm PST
  assert.equal(reminderPlan(at("2027-07-02T02:00:00Z")).habits, true); // 7pm PDT
  assert.equal(reminderPlan(at("2026-11-28T02:00:00Z")).habits, false); // 6pm
});

test("Monday 8am weekly challenge note; 1st of the month at 9am", () => {
  assert.equal(reminderPlan(at("2026-11-30T16:00:00Z")).challengeWeekly, true); // Mon 8am
  assert.equal(reminderPlan(at("2026-12-01T16:00:00Z")).challengeWeekly, false); // Tue 8am
  assert.equal(reminderPlan(at("2026-12-01T17:00:00Z")).monthly, true); // Dec 1 9am
  assert.equal(reminderPlan(at("2026-12-01T16:00:00Z")).monthly, false); // 8am
  assert.equal(reminderPlan(at("2026-12-01T07:30:00Z")).monthly, false); // still Nov 30 Pacific
});

test("a session reminder is due within 24 hours, once, never in the last hour", () => {
  const booking = { date: "2026-12-02", slotMin: 18 * 60, createdAt: "2026-11-20T00:00:00Z" }; // 6pm Dec 2 PST = 02:00Z Dec 3
  assert.equal(sessionReminderDue(booking, at("2026-12-02T01:00:00Z")), false); // 25h before
  assert.equal(sessionReminderDue(booking, at("2026-12-02T02:00:00Z")), true); // 24h before
  assert.equal(sessionReminderDue(booking, at("2026-12-03T01:00:00Z")), false); // 1h before
  // Booked less than a day ahead: the confirmation is enough.
  assert.equal(sessionReminderDue({ ...booking, createdAt: "2026-12-02T10:00:00Z" }, at("2026-12-02T12:00:00Z")), false);
});

test("an early session's reminder waits for 8am the day before", () => {
  const sixAm = { date: "2026-12-03", slotMin: 6 * 60, createdAt: "2026-11-01T00:00:00Z" }; // 14:00Z Dec 3
  const quietRun = at("2026-12-02T14:00:00Z"); // 6am Dec 2, 24h before, quiet
  assert.equal(reminderPlan(quietRun).sessions, false);
  const eightAm = at("2026-12-02T16:00:00Z");
  assert.equal(reminderPlan(eightAm).sessions, true);
  assert.equal(sessionReminderDue(sixAm, eightAm), true);
});

test("labels and challenge helpers", () => {
  assert.equal(slotLabel(18 * 60 + 30), "6:30 PM");
  assert.equal(slotLabel(0), "12:00 AM");
  assert.equal(sessionDayWord("2026-11-28", "2026-11-27"), "tomorrow");
  assert.deepEqual(challengeParticipants({ participants: ["a", "b", "a", ""] }), ["a", "b"]);
  assert.equal(challengeActive({ start_date: "2026-11-01", end_date: "2026-11-30" }, "2026-11-27"), true);
  assert.equal(challengeClosesInTwoDays({ end_date: "2026-11-29" }, "2026-11-27"), true);
});

test("habit reminder only when habits exist and today has no log", () => {
  assert.equal(habitReminderDue({ habits: ["water"] }, "2026-11-27"), true);
  assert.equal(habitReminderDue({ habits: ["water"], habitLogByDate: { "2026-11-27": { water: true } } }, "2026-11-27"), false);
  assert.equal(habitReminderDue({ habits: [] }, "2026-11-27"), false);
});
