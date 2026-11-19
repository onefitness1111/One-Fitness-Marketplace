import assert from "node:assert/strict";
import test from "node:test";
import { coachDisplayName } from "./coachName.mjs";

test("a client sees the coach name, or your coach, never a legal name", () => {
  assert.equal(coachDisplayName("Coach Chris"), "Coach Chris");
  assert.equal(coachDisplayName("  "), "your coach");
  assert.equal(coachDisplayName(null), "your coach");
  assert.equal(coachDisplayName(undefined), "your coach");
  assert.equal(coachDisplayName(""), "your coach");
});
