import assert from "node:assert/strict";
import test from "node:test";
import {
  clientBalanceMessage,
  clientMayBuySingle,
  coachFreeAddBlocked,
  pacificWeekRange,
  priceFromSettings,
  staffMayAddSingle,
} from "./singleSessionRules.mjs";

test("the price comes only from the settings entry", () => {
  assert.deepEqual(priceFromSettings({ priceCents: 4000, allowed: true }), { allowed: true, priceCents: 4000 });
  assert.deepEqual(priceFromSettings({ priceCents: 4000, allowed: false }), { allowed: false, priceCents: 4000 });
  assert.deepEqual(priceFromSettings({ priceCents: 0, allowed: true }), { allowed: false, priceCents: 0 });
  assert.deepEqual(priceFromSettings(undefined), { allowed: false, priceCents: 0 });
});

test("a client who owes cannot buy or book a single session", () => {
  assert.equal(clientMayBuySingle(0), true);
  assert.equal(clientMayBuySingle(500), true);
  assert.equal(clientMayBuySingle(-2500), false);
  assert.equal(
    clientBalanceMessage(-2500),
    "You have an outstanding balance of $25.00. Please pay your balance to book sessions.",
  );
});

test("a coach gets one grace add and the owner is not limited", () => {
  assert.deepEqual(staffMayAddSingle({ role: "coach", balanceCents: -2500, graceUsed: false }), {
    ok: true,
    consumeGrace: true,
  });
  const blocked = staffMayAddSingle({ role: "coach", balanceCents: -2500, graceUsed: true });
  assert.equal(blocked.ok, false);
  assert.equal(blocked.message, "This client has an outstanding balance of $25.00.");
  assert.deepEqual(staffMayAddSingle({ role: "owner", balanceCents: -2500, graceUsed: true }), {
    ok: true,
    consumeGrace: false,
  });
  assert.deepEqual(staffMayAddSingle({ role: "coach", balanceCents: 0, graceUsed: true }), {
    ok: true,
    consumeGrace: false,
  });
});

test("the free-add week starts Monday midnight Pacific", () => {
  const range = pacificWeekRange(new Date("2026-11-18T20:00:00.000Z"));
  assert.equal(range.start, "2026-11-16T08:00:00.000Z");
  assert.equal(range.end, "2026-11-23T08:00:00.000Z");
});

test("a coach's second free add in the week is refused, the owner's is not", () => {
  assert.equal(coachFreeAddBlocked({ role: "coach", usedThisWeek: 0 }), false);
  assert.equal(coachFreeAddBlocked({ role: "coach", usedThisWeek: 1 }), true);
  assert.equal(coachFreeAddBlocked({ role: "owner", usedThisWeek: 4 }), false);
});
