import assert from "node:assert/strict";
import test from "node:test";
import {
  afterSingleSessionPayment,
  coachFreeAddBlocked,
  filledSessionRefundNotice,
  pacificWeekRange,
  priceFromSettings,
  singleSessionBreakdown,
  singleSessionTotal,
  staffMayAddSingle,
} from "./singleSessionRules.mjs";

test("the price comes only from the settings entry", () => {
  assert.deepEqual(priceFromSettings({ priceCents: 4000, allowed: true }), { allowed: true, priceCents: 4000 });
  assert.deepEqual(priceFromSettings({ priceCents: 4000, allowed: false }), { allowed: false, priceCents: 4000 });
  assert.deepEqual(priceFromSettings({ priceCents: 0, allowed: true }), { allowed: false, priceCents: 0 });
  assert.deepEqual(priceFromSettings(undefined), { allowed: false, priceCents: 0 });
});

test("a single-session charge adds the outstanding balance", () => {
  const bill = singleSessionTotal(4000, -2500);
  assert.deepEqual(bill, { sessionCents: 4000, balanceCents: 2500, totalCents: 6500 });
  assert.equal(singleSessionBreakdown(bill), "Session $40.00 + balance $25.00 = total $65.00");
  assert.deepEqual(singleSessionTotal(4000, 0), { sessionCents: 4000, balanceCents: 0, totalCents: 4000 });
  assert.equal(singleSessionBreakdown(singleSessionTotal(4000, 500)), "");
  assert.deepEqual(afterSingleSessionPayment(true), { settleBalance: true, refundWholeCharge: false });
  assert.deepEqual(afterSingleSessionPayment(false), { settleBalance: false, refundWholeCharge: true });
});

test("a filled session tells the payer the whole charge was refunded", () => {
  assert.equal(
    filledSessionRefundNotice({ chargedCents: 6500, balanceCents: 2500 }),
    "This session filled before your booking went through. Your $65.00 charge has been refunded. Your outstanding balance of $25.00 is unchanged.",
  );
  assert.equal(
    filledSessionRefundNotice({ chargedCents: 4000, balanceCents: 0 }),
    "This session filled before your booking went through. Your $40.00 charge has been refunded.",
  );
  const staff = filledSessionRefundNotice({ chargedCents: 6500, balanceCents: 2500, clientName: "Alex Client" });
  assert.match(staff, /^Alex Client's session filled/);
  assert.match(staff, /Their outstanding balance of \$25\.00 is unchanged\./);
  assert.equal(staff.includes("555"), false);
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
