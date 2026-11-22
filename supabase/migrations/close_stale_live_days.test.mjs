import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261122160000_close_stale_live_days.sql", import.meta.url), "utf8");

test("the sweep only closes the live marker", () => {
  const body = sql.slice(sql.indexOf("create or replace function public.close_stale_live_days"), sql.indexOf("revoke all on function public.close_stale_live_days"));
  assert.ok(body.includes("update public.live_day_runs r"));
  assert.ok(body.includes("set ended_at = now()"));
  assert.ok(body.includes("s.updated_at >= now() - p_idle"));
  assert.equal(/delete\s+from/i.test(body), false);
  assert.equal(body.includes("update public.live_set_logs"), false);
  assert.equal(body.includes("client_records"), false);
});

test("the job is replaced, not stacked, and runs every 15 minutes", () => {
  assert.ok(sql.includes("cron.unschedule(existing)"));
  assert.ok(sql.includes("'close-stale-live-days',\n      '*/15 * * * *'"));
});

test("starting a day also closes the same day left open on another date", () => {
  assert.ok(sql.includes("(day_id is distinct from p_day or log_date is distinct from p_date)"));
});

test("only the scheduler can run the sweep", () => {
  assert.ok(sql.includes("from public, anon, authenticated"));
  assert.equal(sql.includes("close_stale_live_days(interval) to authenticated"), false);
});

test("no assignment gate", () => {
  assert.equal(sql.includes("primary_trainer_id"), false);
});
