import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  REWARD_MAX_REDEEM_POINTS,
  REWARD_MIN_REDEEM_POINTS,
  planRedemption,
  pointsToDiscountCents,
  replayLedger,
} from "./pointsLedger.ts";

const now = new Date("2026-11-25T12:00:00.000Z");

const earnRow = (id, amount, createdAt = "2026-11-01T12:00:00.000Z") => ({
  id,
  amount,
  type: "earn",
  source: "challenge_1st",
  created_at: createdAt,
  expires_at: "2027-05-01T12:00:00.000Z",
});

test("L8 constants enforce 40 min and 100 max per single redemption", () => {
  assert.equal(REWARD_MIN_REDEEM_POINTS, 40);
  assert.equal(REWARD_MAX_REDEEM_POINTS, 100);
});

test("balances accumulate past 100 with no balance cap", () => {
  const rows = [
    earnRow("a", 60, "2026-10-01T12:00:00.000Z"),
    earnRow("b", 90, "2026-10-15T12:00:00.000Z"),
  ];
  const { lots, balance } = replayLedger(rows, now);
  assert.equal(balance, 150);

  const plan = planRedemption(lots, now);
  assert.equal(plan.points, 100);
  assert.deepEqual(plan.allocations, [
    { lotId: "a", amount: 60 },
    { lotId: "b", amount: 40 },
  ]);

  const after = replayLedger(
    [
      ...rows,
      {
        id: "r1",
        amount: -100,
        type: "redeem",
        source: "redemption_checkout",
        created_at: "2026-11-20T12:00:00.000Z",
      },
    ],
    now,
  );
  assert.equal(after.balance, 50);
  assert.equal(planRedemption(after.lots, now).points, 50);
});

test("redemption requires at least 40 points and scales 0.5% per point up to 50%", () => {
  assert.equal(planRedemption(replayLedger([earnRow("a", 39)], now).lots, now), null);
  assert.equal(planRedemption(replayLedger([earnRow("a", 40)], now).lots, now).points, 40);
  assert.equal(planRedemption(replayLedger([earnRow("a", 75)], now).lots, now).points, 75);
  assert.equal(planRedemption(replayLedger([earnRow("a", 100)], now).lots, now).points, 100);
  // Even if someone passes a higher cap or lower min, bounds clamp to 40..100.
  assert.equal(
    planRedemption(replayLedger([earnRow("a", 150)], now).lots, now, { capPoints: 200, minPoints: 10 }).points,
    100,
  );
  assert.equal(
    planRedemption(replayLedger([earnRow("a", 30)], now).lots, now, { capPoints: 100, minPoints: 10 }),
    null,
  );
  assert.equal(pointsToDiscountCents(40, 10000), 2000);
  assert.equal(pointsToDiscountCents(100, 10000), 5000);
});

test("checkout and payment-intent edge functions use the shared 40..100 bounds", () => {
  for (const file of [
    "../create-checkout-session/index.ts",
    "../create-payment-intent/index.ts",
  ]) {
    const src = readFileSync(new URL(file, import.meta.url), "utf8");
    assert.match(src, /REWARD_MAX_REDEEM_POINTS/);
    assert.match(src, /REWARD_MIN_REDEEM_POINTS/);
    assert.doesNotMatch(src, /capPoints:\s*40/);
  }
});

test("migration enforces 40..100 redemption bounds at the database layer", () => {
  const sql = readFileSync(
    new URL("../../migrations/20261125160000_reward_redemption_bounds.sql", import.meta.url),
    "utf8",
  );
  assert.match(sql, /enforce_points_redemption_bounds/);
  assert.match(sql, /new\.amount\s*>\s*-40\s+or\s+new\.amount\s*<\s*-100/);
  assert.match(sql, /POINTS_REDEMPTION_OUT_OF_RANGE/);
});
