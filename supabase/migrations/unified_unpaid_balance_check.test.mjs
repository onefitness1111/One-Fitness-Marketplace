import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { evaluateUnpaidBalance, staffMayAddSingle } from "../functions/_shared/singleSessionRules.mjs";

const migration = readFileSync(
  new URL("./20261125170000_unified_unpaid_balance_check.sql", import.meta.url),
  "utf8",
);
const staffSingle = readFileSync(
  new URL("../functions/staff-single-session/index.ts", import.meta.url),
  "utf8",
);

test("migration defines one shared unpaid_balance_rule used by check_booking_balance, policies, triggers, and book_single_session", () => {
  assert.match(migration, /create or replace function public\.unpaid_balance_rule\(/);
  assert.match(migration, /create or replace function public\.check_booking_balance\(/);
  assert.match(migration, /create or replace function public\.booking_balance_allowed\(/);
  assert.match(migration, /with check \(public\.booking_balance_allowed\(client_id, 'booking'\)\)/);
  assert.match(migration, /with check \(public\.booking_balance_allowed\(client_id, 'waitlist'\)\)/);
  assert.match(migration, /from public\.unpaid_balance_rule\(owed, used, new\.client_id/);
  assert.match(migration, /from public\.unpaid_balance_rule\(owed, grace_used, c\.client_id/);
  assert.match(migration, /if c\.source not in \('purchase', 'staff_charge'\)/);
  // Privacy: check_booking_balance never returns phone/address and rejects unauthorized callers.
  assert.match(migration, /'NOT_AUTHORIZED'/);
  const sqlCode = migration.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n").replace(/comment on function[\s\S]*?;/gi, "");
  assert.doesNotMatch(sqlCode, /\b(phone|billing_address)\b/i);
});

test("staff-single-session routes its free-add gate through check_booking_balance", () => {
  assert.match(staffSingle, /admin\.rpc\("check_booking_balance"/);
  assert.doesNotMatch(staffSingle, /grace_booking_used/);
});

test("JS mirror evaluateUnpaidBalance matches owner override, coach 1-time grace, waitlist, and client block", () => {
  assert.equal(evaluateUnpaidBalance({ balanceCents: -2500, isSelf: true, role: "client" }).code, "BALANCE_DUE");
  assert.equal(evaluateUnpaidBalance({ balanceCents: -2500, isSelf: true, role: "client", target: "waitlist" }).code, "BALANCE_DUE");
  assert.equal(evaluateUnpaidBalance({ balanceCents: -2500, isSelf: false, role: "coach", graceUsed: false }).consumeGrace, true);
  assert.equal(evaluateUnpaidBalance({ balanceCents: -2500, isSelf: false, role: "coach", graceUsed: true }).code, "BALANCE_GRACE_USED");
  assert.equal(evaluateUnpaidBalance({ balanceCents: -2500, isSelf: false, role: "owner", graceUsed: true }).allowed, true);
  assert.equal(evaluateUnpaidBalance({ balanceCents: -2500, isSelf: false, role: "owner", graceUsed: true, target: "waitlist" }).allowed, true);
  assert.equal(staffMayAddSingle({ role: "coach", balanceCents: -2500, graceUsed: true }).code, "BALANCE_GRACE_USED");
});

test("coach waitlist add is allowed before grace, blocked with BALANCE_GRACE_USED after, and never consumes grace", () => {
  const before = evaluateUnpaidBalance({
    balanceCents: -2500,
    isSelf: false,
    role: "coach",
    graceUsed: false,
    target: "waitlist",
  });
  assert.equal(before.allowed, true);
  assert.equal(before.code, "OK");
  assert.equal(before.consumeGrace, false);

  const after = evaluateUnpaidBalance({
    balanceCents: -2500,
    isSelf: false,
    role: "coach",
    graceUsed: true,
    target: "waitlist",
  });
  assert.equal(after.allowed, false);
  assert.equal(after.code, "BALANCE_GRACE_USED");
  assert.equal(after.consumeGrace, false);
  assert.equal(after.message, "This client has an outstanding balance of $25.00.");

  const self = evaluateUnpaidBalance({
    balanceCents: -2500,
    isSelf: true,
    role: "coach",
    graceUsed: false,
    target: "waitlist",
  });
  assert.equal(self.code, "BALANCE_DUE");

  const waitlistRule = migration.slice(
    migration.indexOf("if target = 'waitlist'"),
    migration.indexOf("-- Booking:"),
  );
  assert.match(waitlistRule, /p_actor_role = 'owner'/);
  assert.match(waitlistRule, /p_actor_role = 'coach'/);
  assert.match(waitlistRule, /if used then[\s\S]*'BALANCE_GRACE_USED'/);
  assert.match(waitlistRule, /return query select true, 'OK'::text, null::text, false, true;/);
  assert.match(waitlistRule, /'BALANCE_DUE'/);
});
