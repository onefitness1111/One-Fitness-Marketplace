import assert from "node:assert/strict";
import test from "node:test";
import { firstChargePlanCents, firstChargeSentence, membershipFirstCharge, money } from "./billingAnchor.mjs";

const may30 = new Date("2026-05-30T18:00:00.000Z");
const may21 = new Date("2026-05-21T15:00:00.000Z");
const may20 = new Date("2026-05-20T18:00:00.000Z");

test("May 30 on a $348 plan prorates through June 21 at midnight Pacific", () => {
  const quote = membershipFirstCharge(may30, 34800, 21);
  assert.equal(quote.proratedCents, 24697);
  assert.equal(quote.nextChargeDate, "2026-06-21");
  assert.equal(quote.fullMonth, false);
  // June 21, 2026 12:00 AM PDT is 07:00 UTC.
  assert.equal(quote.nextChargeAt, "2026-06-21T07:00:00.000Z");
  assert.equal(
    firstChargeSentence(quote, null),
    "Today $246.97, prorated through June 21, 2026. Next full charge $348.00 on June 21, 2026.",
  );
});

test("buying on the 21st is a full month and the next charge is the following 21st", () => {
  const quote = membershipFirstCharge(may21, 34800, 21);
  assert.equal(quote.proratedCents, 34800);
  assert.equal(quote.fullMonth, true);
  assert.equal(quote.nextChargeDate, "2026-06-21");
  assert.equal(
    firstChargeSentence(quote, null),
    "Today $348.00, a full month. Next full charge $348.00 on June 21, 2026.",
  );
});

test("the day before the anchor uses this month, at midnight Pacific", () => {
  const quote = membershipFirstCharge(may20, 34800, 21);
  assert.equal(quote.nextChargeDate, "2026-05-21");
  // May 21, 2026 12:00 AM PDT is 07:00 UTC, not midnight UTC the evening before.
  assert.equal(quote.nextChargeAt, "2026-05-21T07:00:00.000Z");
  assert.equal(quote.proratedCents, moneyToCents(quote) > 0 ? quote.proratedCents : 0);
  assert.ok(quote.proratedCents < 34800);
});

test("a one-time coupon discounts only the prorated charge", () => {
  const quote = membershipFirstCharge(may30, 34800, 21);
  const sentence = firstChargeSentence(quote, { type: "flat", flatOffCents: 5000, duration: "once" });
  assert.equal(
    sentence,
    "Today $196.97, prorated through June 21, 2026 ($50.00 off, first payment only). Next full charge $348.00 on June 21, 2026.",
  );
});

test("an every-month coupon also comes off the next full charge", () => {
  const quote = membershipFirstCharge(may30, 34800, 21);
  const sentence = firstChargeSentence(quote, { type: "flat", flatOffCents: 5000, duration: "forever" });
  assert.match(sentence, /Next charge \$298\.00 on June 21, 2026\./);
});

test("winter midnight is 08:00 UTC", () => {
  const quote = membershipFirstCharge(new Date("2026-01-10T20:00:00.000Z"), 10000, 21);
  assert.equal(quote.nextChargeDate, "2026-01-21");
  assert.equal(quote.nextChargeAt, "2026-01-21T08:00:00.000Z");
});

test("money formats cents", () => {
  assert.equal(money(24697), "$246.97");
});

function moneyToCents(quote) {
  return quote.proratedCents;
}

const nov22 = new Date("2026-11-22T17:00:00.000Z");

test("owner full price now: Nov 22 charges $348 today and $348 on December 21", () => {
  const quote = membershipFirstCharge(nov22, 34800, 21);
  assert.equal(quote.proratedCents, 33640);
  assert.equal(quote.nextChargeDate, "2026-12-21");
  assert.equal(firstChargePlanCents(quote, { fullFirstCharge: true }), 34800);
  assert.equal(firstChargePlanCents(quote), 33640);
  assert.equal(
    firstChargeSentence(quote, null, { fullFirstCharge: true }),
    "Today $348.00, full price. Next full charge $348.00 on December 21, 2026.",
  );
  assert.equal(
    firstChargeSentence(quote, null),
    "Today $336.40, prorated through December 21, 2026. Next full charge $348.00 on December 21, 2026.",
  );
});

test("owner full price now: a percent coupon comes off the full amount", () => {
  const quote = membershipFirstCharge(nov22, 34800, 21);
  assert.equal(
    firstChargeSentence(quote, { type: "percent", percentOff: 10, duration: "once" }, { fullFirstCharge: true }),
    "Today $313.20, full price (10% off, first payment only). Next full charge $348.00 on December 21, 2026.",
  );
});

test("owner full price now on the anchor day itself reads as a full month", () => {
  const quote = membershipFirstCharge(may21, 34800, 21);
  assert.equal(
    firstChargeSentence(quote, null, { fullFirstCharge: true }),
    "Today $348.00, a full month. Next full charge $348.00 on June 21, 2026.",
  );
});
