import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261118160000_live_days_history_notify.sql", import.meta.url), "utf8");

test("a workout finish with no day still closes that date", () => {
  const body = sql.slice(sql.indexOf("create or replace function public.end_live_logs"));
  const nullDay = body.indexOf("if p_day is null then");
  const namedDay = body.indexOf("and day_id = p_day");
  assert.ok(nullDay > 0, "missing the no-day path");
  assert.ok(namedDay > nullDay, "the named day should be handled after the no-day path");
  assert.equal(body.includes("Say which day to finish"), false);
});

test("session-run beeps keep their existing insert rule", () => {
  assert.equal(sql.includes("drop policy if exists beeps_insert on public.beeps"), false);
  assert.ok(sql.includes("create policy beeps_insert_live_day on public.beeps"));
});
