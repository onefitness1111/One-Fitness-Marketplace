import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261127110000_sms_safety_and_queue.sql", import.meta.url), "utf8");
const code = sql.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n");

test("only the server can mark or look up a phone", () => {
  for (const fn of ["sms_phone_tail(text)", "sms_phone_status(text)", "sms_mark_phone(text, text)"]) {
    assert.ok(code.includes(`revoke all on function public.${fn} from public, anon, authenticated;`), fn);
    assert.ok(code.includes(`grant execute on function public.${fn} to service_role;`), fn);
  }
  assert.equal(/grant execute[^;]*sms_[^;]*(anon|authenticated)/.test(code), false);
});

test("STOP clears consent the same way an inbound STOP does", () => {
  assert.ok(code.includes("set sms_opted_out = true, sms_consent_at = null, sms_consent_text = null"));
  assert.ok(code.includes("set sms_opt_in = false, sms_opt_in_at = null, sms_consent_text = null"));
});

test("queue and log are owner-read only and hold no phone numbers", () => {
  assert.ok(code.includes("alter table public.sms_outbox enable row level security;"));
  assert.ok(code.includes("alter table public.sms_log enable row level security;"));
  const log = code.slice(code.indexOf("create table if not exists public.sms_log"));
  assert.equal(/\bphone\b|\bbody\b/.test(log.slice(0, log.indexOf(");"))), false);
});

test("no coach-assignment field is used", () => {
  assert.equal(code.includes("primary_trainer_id"), false);
});
