import assert from "node:assert/strict";
import test from "node:test";
import {
  CACHE_CONTROL,
  businessTimeZone,
  calendarSyncAllowed,
  coachLabelForClient,
  eventRevision,
  fold,
  foldedLineOctets,
  sessionMinutes,
  wallTimeToUtc,
} from "./calendarFeed.mjs";

test("the gym clock defaults to Pacific, not Eastern", () => {
  assert.equal(businessTimeZone(undefined), "America/Los_Angeles");
  assert.equal(businessTimeZone({}), "America/Los_Angeles");
  assert.equal(businessTimeZone({ workouts: { businessTimeZone: "America/Chicago" } }), "America/Chicago");
});

test("a stored session length is kept, and a missing one is an hour", () => {
  assert.equal(sessionMinutes(45), 45);
  assert.equal(sessionMinutes("30"), 30);
  assert.equal(sessionMinutes(null), 60);
  assert.equal(sessionMinutes(0), 60);
});

test("a client event uses the public coach name, never a legal name", () => {
  assert.equal(coachLabelForClient("Coach Testy"), "Coach Testy");
  assert.equal(coachLabelForClient(""), "your coach");
  assert.equal(coachLabelForClient("Coach Testy").includes("Legal"), false);
});

test("10:00 Pacific is 18:00 UTC in winter and 17:00 UTC in summer", () => {
  assert.equal(wallTimeToUtc("2026-01-15", 10 * 60, "America/Los_Angeles").toISOString(), "2026-01-15T18:00:00.000Z");
  assert.equal(wallTimeToUtc("2026-07-15", 10 * 60, "America/Los_Angeles").toISOString(), "2026-07-15T17:00:00.000Z");
});

test("lines fold on bytes and do not split a character", () => {
  const em = "\u2014";
  const folded = fold(`SUMMARY:${em.repeat(40)}`);
  const sizes = foldedLineOctets(folded);
  assert.ok(sizes.length > 1);
  assert.ok(sizes.every((n) => n <= 75));
  assert.equal(folded.split("\r\n").slice(1).every((part) => part.startsWith(" ")), true);

  const almost = `${"a".repeat(74)}\u00e9`;
  const foldedAccent = fold(`X:${almost}`);
  assert.ok(foldedLineOctets(foldedAccent).every((n) => n <= 75));
  assert.equal(foldedAccent.includes("\u00e9"), true);
  assert.equal(foldedAccent.includes("\uFFFD"), false);
});

test("a reschedule gets a later sequence from updated_at", () => {
  const first = eventRevision("2026-11-19T18:00:00.000Z");
  const moved = eventRevision("2026-11-19T19:30:00.000Z");
  assert.equal(first.lastModified, "20261119T180000Z");
  assert.ok(moved.sequence > first.sequence);
  assert.equal(eventRevision(null).sequence, 0);
});

test("the owner has no calendar feed; clients and coaches do", () => {
  assert.equal(calendarSyncAllowed("owner"), false);
  assert.equal(calendarSyncAllowed("client"), true);
  assert.equal(calendarSyncAllowed("coach"), true);
  assert.equal(calendarSyncAllowed(null), false);
});

test("the feed is not cacheable by a shared cache", () => {
  assert.equal(CACHE_CONTROL, "private, max-age=900");
  assert.equal(CACHE_CONTROL.includes("public"), false);
});
