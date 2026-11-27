import assert from "node:assert/strict";
import test from "node:test";
import { addDaysIso, pacificEpoch, pacificParts, quietHoursEnd, smsQuietHours } from "./quietHours.mjs";
import { smsQuietHours as broadcastQuiet } from "./broadcastRules.mjs";
import { phoneTail, textableNumber } from "./phoneRules.mjs";

test("quiet hours are 9pm to 8am Pacific, in winter and summer", () => {
  // Nov 27, 2026 is PST (UTC-8).
  assert.equal(smsQuietHours(new Date("2026-11-27T04:59:00Z")), false); // 8:59pm
  assert.equal(smsQuietHours(new Date("2026-11-27T05:00:00Z")), true); // 9:00pm
  assert.equal(smsQuietHours(new Date("2026-11-27T15:59:00Z")), true); // 7:59am
  assert.equal(smsQuietHours(new Date("2026-11-27T16:00:00Z")), false); // 8:00am
  // Jul 1, 2027 is PDT (UTC-7).
  assert.equal(smsQuietHours(new Date("2027-07-01T15:00:00Z")), false); // 8:00am
  assert.equal(smsQuietHours(new Date("2027-07-01T14:59:00Z")), true); // 7:59am
  assert.equal(broadcastQuiet(new Date("2026-11-27T05:00:00Z")), true);
});

test("a deferred text waits for the next 8:00am Pacific", () => {
  assert.equal(quietHoursEnd(new Date("2026-11-27T06:30:00Z")).toISOString(), "2026-11-27T16:00:00.000Z");
  assert.equal(quietHoursEnd(new Date("2026-11-27T13:00:00Z")).toISOString(), "2026-11-27T16:00:00.000Z");
  assert.equal(quietHoursEnd(new Date("2027-07-01T05:00:00Z")).toISOString(), "2027-07-01T15:00:00.000Z");
  const day = new Date("2026-11-27T20:00:00Z");
  assert.equal(quietHoursEnd(day).getTime(), day.getTime());
});

test("Pacific wall clock and booking instants", () => {
  assert.deepEqual(pacificParts(new Date("2026-11-30T16:05:00Z")).weekday, 1);
  assert.equal(pacificParts(new Date("2026-12-01T07:59:00Z")).date, "2026-11-30");
  assert.equal(new Date(pacificEpoch("2026-11-30", 7 * 60)).toISOString(), "2026-11-30T15:00:00.000Z");
  assert.equal(new Date(pacificEpoch("2027-07-01", 7 * 60)).toISOString(), "2027-07-01T14:00:00.000Z");
  assert.equal(new Date(pacificEpoch("2027-03-14", 10 * 60)).toISOString(), "2027-03-14T17:00:00.000Z");
  assert.equal(addDaysIso("2026-12-31", 1), "2027-01-01");
});

test("made-up numbers are not texted", () => {
  assert.equal(textableNumber("(818) 223-7001"), "+18182237001");
  assert.equal(textableNumber("+1 818 223 7001"), "+18182237001");
  assert.equal(textableNumber("1234567890"), null);
  assert.equal(textableNumber("0000000000"), null);
  assert.equal(textableNumber("5555555555"), null);
  assert.equal(textableNumber("8185550123"), null);
  assert.equal(textableNumber("818223700"), null);
  assert.equal(textableNumber(""), null);
  assert.equal(textableNumber("+44 20 7946 0958"), "+442079460958");
  assert.equal(phoneTail("+18182237001"), "7001");
});
