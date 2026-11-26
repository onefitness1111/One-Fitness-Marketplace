import assert from "node:assert/strict";
import test from "node:test";
import {
  CACHE_CONTROL,
  businessTimeZone,
  calendarFeedScopeColumn,
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

test("U13: clients, coaches and the owner can sync; nobody else", () => {
  assert.equal(calendarSyncAllowed("owner"), true);
  assert.equal(calendarSyncAllowed("client"), true);
  assert.equal(calendarSyncAllowed("coach"), true);
  assert.equal(calendarSyncAllowed(null), false);
  assert.equal(calendarSyncAllowed("anon"), false);
});

test("U13: the owner's feed is scoped to sessions the owner runs, like a coach", () => {
  assert.equal(calendarFeedScopeColumn("owner"), "trainer_id");
  assert.equal(calendarFeedScopeColumn("coach"), "trainer_id");
  assert.equal(calendarFeedScopeColumn("client"), "client_id");
});

test("U13: both edge functions use the shared rule and no longer refuse the owner", async () => {
  const { readFile } = await import("node:fs/promises");
  const link = await readFile(new URL("../get-calendar-link/index.ts", import.meta.url), "utf8");
  const feed = await readFile(new URL("../calendar-feed/index.ts", import.meta.url), "utf8");
  assert.ok(link.includes("calendarSyncAllowed(profile?.role)"));
  assert.equal(link.includes('profile?.role === "owner"'), false);
  assert.ok(feed.includes("calendarFeedScopeColumn(profile.role)"));
});

test("the feed is not cacheable by a shared cache", () => {
  assert.equal(CACHE_CONTROL, "private, max-age=900");
  assert.equal(CACHE_CONTROL.includes("public"), false);
});
