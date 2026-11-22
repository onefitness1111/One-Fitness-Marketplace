import assert from "node:assert/strict";
import test from "node:test";
import {
  assertPlanPurchasable,
  clientCatalogVisible,
  planStatus,
  purchaseBlockReason,
  staffMayAssign,
} from "./planVisibility.mjs";

test("a row with no status follows the archived flag", () => {
  assert.equal(planStatus({ archived: false }), "active");
  assert.equal(planStatus({}), "active");
  assert.equal(planStatus({ archived: true }), "archived");
});

test("an explicit status wins over a stale archived flag", () => {
  assert.equal(planStatus({ status: "ghost", archived: true }), "ghost");
  assert.equal(planStatus({ status: "Ghost" }), "ghost");
  assert.equal(planStatus({ status: "active", archived: true }), "active");
});

test("clients do not see ghost or archived plans in the catalog", () => {
  assert.equal(clientCatalogVisible({ status: "active" }), true);
  assert.equal(clientCatalogVisible({ status: "ghost" }), false);
  assert.equal(clientCatalogVisible({ status: "archived" }), false);
  assert.equal(clientCatalogVisible({ archived: true }), false);
});

test("staff can assign a ghost plan and cannot assign an archived one", () => {
  assert.equal(staffMayAssign({ status: "active" }), true);
  assert.equal(staffMayAssign({ status: "ghost" }), true);
  assert.equal(staffMayAssign({ status: "archived" }), false);
});

test("a client cannot buy a ghost plan", () => {
  const ghost = { status: "ghost", archived: false, name: "Legacy 8" };
  assert.equal(purchaseBlockReason(ghost), "That plan isn't offered for purchase.");
  assert.throws(() => assertPlanPurchasable(ghost), /isn't offered for purchase/);
});

test("staff can enroll a client on a ghost plan", () => {
  const ghost = { status: "ghost", priceCents: 22900 };
  assert.equal(purchaseBlockReason(ghost, { staffEnrollingClient: true }), null);
  assert.doesNotThrow(() => assertPlanPurchasable(ghost, { staffEnrollingClient: true }));
});

test("a client renewing a ghost package they already hold is allowed", () => {
  const ghost = { status: "ghost", kind: "package" };
  assert.equal(purchaseBlockReason(ghost, { renewingHeldPlan: true }), null);
});

test("a client cannot buy an archived plan, and staff cannot enroll one", () => {
  const archived = { status: "archived" };
  assert.equal(purchaseBlockReason(archived), "That plan is no longer available.");
  assert.equal(
    purchaseBlockReason(archived, { staffEnrollingClient: true }),
    "That plan is no longer available.",
  );
});

test("an active plan is purchasable by a client", () => {
  assert.equal(purchaseBlockReason({ status: "active" }), null);
  assert.equal(purchaseBlockReason({ archived: false }), null);
});
