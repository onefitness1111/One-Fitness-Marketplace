import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261122160000_close_stale_live_days.sql", import.meta.url), "utf8");

const markers = "exercise_name in ('__day_started_coach__', '__day_started_client__')";

function fnBody(name, nextName) {
  const start = sql.indexOf(`create or replace function public.${name}`);
  assert.ok(start >= 0, `${name} is missing`);
  const end = nextName ? sql.indexOf(`create or replace function public.${nextName}`, start + 1) : sql.length;
  return sql.slice(start, end);
}

test("the sweep closes stale live-day rows and start markers only", () => {
  const body = fnBody("close_stale_live_days", "start_live_day");
  assert.ok(body.includes("update public.live_day_runs r"));
  assert.ok(body.includes("set ended_at = now()"));
  assert.ok(body.includes("s.updated_at >= now() - p_idle"));
  assert.ok(body.includes("update public.live_set_logs s"));
  assert.ok(body.includes(markers));
  assert.equal(/delete\s+from/i.test(body), false);
  assert.equal(body.includes("client_records"), false);
  // Real set rows must never be ended by this update.
  const markerUpdate = body.slice(body.indexOf("update public.live_set_logs s"));
  assert.ok(markerUpdate.includes(markers));
});

test("the job is replaced, not stacked, and runs every 15 minutes", () => {
  assert.ok(sql.includes("cron.unschedule(existing)"));
  assert.ok(sql.includes("'close-stale-live-days',\n      '*/15 * * * *'"));
});

test("starting a day also closes the same day left open on another date", () => {
  const body = fnBody("start_live_day", "end_open_live_days");
  assert.ok(body.includes("(day_id is distinct from p_day or log_date is distinct from p_date)"));
  assert.ok(body.includes("update public.live_set_logs"));
  assert.ok(body.includes(markers));
});

test("ending a live day closes start markers and not real set rows", () => {
  const body = fnBody("end_open_live_days");
  assert.ok(body.includes("update public.live_day_runs"));
  assert.ok(body.includes("update public.live_set_logs"));
  assert.ok(body.includes(markers));
  assert.equal(/delete\s+from/i.test(body), false);
  assert.equal(body.includes("client_records"), false);
});

test("only the scheduler can run the sweep", () => {
  assert.ok(sql.includes("from public, anon, authenticated"));
  assert.equal(sql.includes("close_stale_live_days(interval) to authenticated"), false);
});

test("no assignment gate", () => {
  assert.equal(sql.includes("primary_trainer_id"), false);
});
