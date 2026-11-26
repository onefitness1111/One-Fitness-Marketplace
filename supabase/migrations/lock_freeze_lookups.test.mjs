import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261126090000_lock_freeze_lookups.sql", import.meta.url), "utf8");
const code = sql.split("\n").filter((l) => !l.startsWith("--")).join("\n");

test("freeze lookups are closed to anon and signed-in callers", () => {
  assert.ok(code.includes("revoke all on function public.client_frozen_until(uuid, date) from public, anon, authenticated;"));
  assert.ok(code.includes("revoke all on function public.client_plan_hold(uuid, text) from public, anon, authenticated;"));
  assert.equal(/grant execute[^;]*(anon|authenticated)/.test(code), false);
});

test("the trigger-only booking block cannot be called through /rpc", () => {
  assert.ok(code.includes("revoke all on function public.block_frozen_client_booking() from public, anon, authenticated;"));
});

test("no rows change and no coach-assignment field is used", () => {
  assert.equal(/\b(insert|update|delete|drop|alter)\b/i.test(code), false);
  assert.equal(code.includes("primary_trainer_id"), false);
});
