import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  COACH_PERMISSIONS,
  isCoachPermission,
  permissionAllowed,
  permissionDeniedMessage,
} from "./coachPermissions.mjs";

const allOff = Object.fromEntries(COACH_PERMISSIONS.map((p) => [p, false]));
const allOn = Object.fromEntries(COACH_PERMISSIONS.map((p) => [p, true]));

test("six switches, named the same as the database columns", () => {
  assert.deepEqual(COACH_PERMISSIONS, [
    "billing_access",
    "charge_fees",
    "edit_plans",
    "send_texts",
    "manage_other_schedules",
    "see_own_revenue",
  ]);
  const sql = readFileSync(new URL("../../migrations/20261126140000_coach_permissions.sql", import.meta.url), "utf8");
  for (const p of COACH_PERMISSIONS) assert.ok(sql.includes(`${p} boolean not null default false`), p);
});

test("the owner may do everything, with or without a row", () => {
  for (const p of COACH_PERMISSIONS) {
    assert.equal(permissionAllowed("owner", null, p), true);
    assert.equal(permissionAllowed("owner", allOff, p), true);
  }
});

test("a coach may only do what their own switch allows", () => {
  for (const p of COACH_PERMISSIONS) {
    assert.equal(permissionAllowed("coach", allOn, p), true);
    assert.equal(permissionAllowed("coach", allOff, p), false);
    assert.equal(permissionAllowed("coach", { ...allOff, [p]: true }, p), true);
  }
  assert.equal(permissionAllowed("coach", { ...allOff, charge_fees: true }, "send_texts"), false);
});

test("a coach with no row, a client, or no role may do nothing", () => {
  for (const p of COACH_PERMISSIONS) {
    assert.equal(permissionAllowed("coach", null, p), false);
    assert.equal(permissionAllowed("client", allOn, p), false);
    assert.equal(permissionAllowed(undefined, allOn, p), false);
  }
});

test("a typo in a permission name fails closed, even for the owner", () => {
  assert.equal(isCoachPermission("charge_fee"), false);
  assert.equal(permissionAllowed("owner", null, "charge_fee"), false);
  assert.equal(permissionAllowed("coach", { charge_fee: true }, "charge_fee"), false);
});

test("a truthy value that is not true does not count", () => {
  assert.equal(permissionAllowed("coach", { send_texts: "true" }, "send_texts"), false);
  assert.equal(permissionAllowed("coach", { send_texts: 1 }, "send_texts"), false);
});

test("refusals are plain English and never mention internals", () => {
  for (const p of COACH_PERMISSIONS) {
    const m = permissionDeniedMessage(p);
    assert.match(m, /Ask the owner/);
    assert.equal(/primary_trainer|row|policy|rls|\bai\b/i.test(m), false, m);
  }
});

test("the server helper reads only coach_permissions and never primary_trainer_id", () => {
  const ts = readFileSync(new URL("./coachPermissions.ts", import.meta.url), "utf8")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("//"))
    .join("\n");
  assert.ok(ts.includes('.from("coach_permissions")'));
  assert.equal(ts.includes("primary_trainer_id"), false);
  assert.ok(ts.includes("if (error) return false"));
});
