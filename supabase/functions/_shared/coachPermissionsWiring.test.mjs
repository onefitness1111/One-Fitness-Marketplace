import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

// Every server function that does something a switch controls must call
// requireCoachPermission with the right name, after the caller's role is known
// and before the action itself.
const src = (fn) => readFileSync(new URL(`../${fn}/index.ts`, import.meta.url), "utf8");

const WIRING = [
  ["charge-client", ['"billing_access"', '"charge_fees"'], "const secret = Deno.env.get"],
  ["charge-late-cancellation", ['"charge_fees"'], "collectSessionFee(admin"],
  ["charge-attendance-fee", ['"charge_fees"'], "collectSessionFee(admin"],
  ["staff-single-session", ['"manage_other_schedules"', '"charge_fees"'], "const { data: clientRow }"],
  ["send-sms", ['"send_texts"'], "member.phone"],
  ["broadcast-message", ['"send_texts"'], 'rpc("broadcast_allowed_clients"'],
  ["admin-cancel-membership", ['"edit_plans"'], "const { data: clientRow }"],
  ["enroll-free-plan", ['"edit_plans"'], "const { data: planRow }"],
  ["create-payment-intent", ['"edit_plans"'], "const { data: planRow }"],
  ["create-checkout-session", ['"edit_plans"'], "const { data: targetProfile }"],
  ["list-payment-methods", ['"billing_access"'], "const customerId"],
  ["create-setup-intent", ['"billing_access"'], "let customerId"],
  ["save-billing-address", ['"billing_access"'], 'rpc("set_client_billing_address"'],
];

for (const [fn, perms, after] of WIRING) {
  test(`${fn} checks ${perms.join(" and ")} before it acts`, () => {
    const code = src(fn);
    assert.ok(code.includes('from "../_shared/coachPermissions.ts"'), "imports the helper");
    const call = code.indexOf("requireCoachPermission(admin");
    assert.ok(call > 0, "calls the helper with the service client");
    for (const p of perms) assert.ok(code.includes(p), `${p} is named`);
    const action = code.indexOf(after);
    assert.ok(action > 0, `anchor "${after}" exists`);
    assert.ok(call < action, "the check comes before the action");
  });
}

test("no function gates on primary_trainer_id", () => {
  for (const [fn] of WIRING) {
    const code = src(fn)
      .split("\n")
      .filter((l) => !l.trimStart().startsWith("//"))
      .join("\n");
    assert.equal(code.includes("primary_trainer_id"), false, fn);
  }
});

test("a client cancelling their own session skips the staff fee check", () => {
  const code = src("charge-late-cancellation");
  assert.ok(code.includes("if (user.id !== booking.client_id) await requireCoachPermission"));
});

test("only texts need send_texts in a broadcast", () => {
  const code = src("broadcast-message");
  assert.ok(code.includes('if (ways.sms) await requireCoachPermission(admin, userId, role, "send_texts")'));
});

test("refunds and waives are still owner-only (no coach switch)", () => {
  for (const fn of ["refund-charge", "waive-charge"]) {
    const code = src(fn);
    assert.ok(/owner/.test(code), fn);
    assert.equal(code.includes("requireCoachPermission"), false, fn);
  }
});
