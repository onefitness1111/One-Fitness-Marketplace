import assert from "node:assert/strict";
import test from "node:test";
import { stripeCouponDuration } from "./couponDuration.mjs";

test("a coupon with no duration is one time", () => {
  assert.deepEqual(stripeCouponDuration({}), { duration: "once" });
  assert.deepEqual(stripeCouponDuration({ duration: "once" }), { duration: "once" });
});

test("every month is Stripe forever", () => {
  assert.deepEqual(stripeCouponDuration({ duration: "forever" }), { duration: "forever" });
});

test("for N months is Stripe repeating", () => {
  assert.deepEqual(
    stripeCouponDuration({ duration: "repeating", durationInMonths: 3 }),
    { duration: "repeating", duration_in_months: 3 },
  );
  assert.deepEqual(
    stripeCouponDuration({ duration: "repeating", durationInMonths: 0 }),
    { duration: "repeating", duration_in_months: 1 },
  );
  assert.deepEqual(
    stripeCouponDuration({ duration: "repeating", durationInMonths: 99 }),
    { duration: "repeating", duration_in_months: 36 },
  );
});
