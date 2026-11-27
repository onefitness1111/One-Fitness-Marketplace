import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261127130000_hourly_reminders.sql", import.meta.url), "utf8");
const fn = readFileSync(new URL("../functions/send-scheduled-reminders/index.ts", import.meta.url), "utf8");
const sweep = readFileSync(new URL("../functions/waitlist-sweep/index.ts", import.meta.url), "utf8");

test("reminders run hourly and jobs 1-2 read the secret from Vault", () => {
  assert.match(sql, /'send-scheduled-reminders-hourly',\s*'0 \* \* \* \*'/);
  assert.match(sql, /'send-scheduled-reminders-daily'/);
  assert.equal((sql.match(/\(select public\.cron_vault_secret\(\)\)/g) || []).length, 2);
  assert.doesNotMatch(sql, /x-cron-secret',\s*'/, "no secret literal in the job text");
});

test("each reminder is recorded once", () => {
  assert.match(sql, /primary key \(kind, ref, profile_id\)/);
  assert.match(fn, /from\("scheduled_notices"\)\.insert/);
});

test("both timer functions accept the Vault secret", () => {
  assert.match(fn, /isCronRequest\(admin, req\)/);
  assert.match(sweep, /isCronRequest\(admin, req\)/);
});

test("reminder texts only go through the consent + quiet-hours gate", () => {
  assert.doesNotMatch(fn, /sendSms\(/);
  assert.match(fn, /sendAutoSms\(/);
});
