import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261123030000_booking_location_and_swap_stamp.sql", import.meta.url), "utf8");
const code = sql.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n");
const dart = readFileSync(new URL("../../lib/core/supabase/supabase_service.dart", import.meta.url), "utf8");

test("booking_location exists, is bounded, and readable like the other app columns", () => {
  assert.match(code, /alter table public\.clients add column if not exists booking_location text/);
  assert.match(code, /char_length\(booking_location\) between 1 and 120/);
  assert.match(code, /grant select \(booking_location\) on public\.clients to authenticated/);
  assert.doesNotMatch(code, /to anon/);
  assert.doesNotMatch(code, /grant (select|update) on table/);
  // No row policy is loosened; the existing self-or-staff update policy applies.
  assert.doesNotMatch(code, /create policy|drop policy/);
});

test("the app writes and reads back booking_location", () => {
  assert.match(dart, /update\(\{"booking_location": location\}\)\.eq\("profile_id", clientId\)/);
  const cols = /_clientColumns\s*=\s*"([^"]+)"/.exec(dart)[1].split(",").map((c) => c.trim());
  assert.ok(cols.includes("booking_location"));
  assert.match(dart, /bookingLocation: c\["booking_location"\]/);
});

test("swap stamp only moves when a workout gains or changes its swaps", () => {
  const fn = code.slice(code.indexOf("function public.client_records_stamp_swap"), code.indexOf("revoke all on function public.client_records_stamp_swap"));
  assert.match(fn, /new\.swaps_at := old\.swaps_at/);
  assert.match(fn, /is not distinct from \(old\.data -> 'workoutLogs'\)/);
  assert.match(fn, /\(prev -> 'swaps'\) is distinct from \(e -> 'swaps'\)/);
  assert.match(code, /before insert or update on public\.client_records/);
  assert.match(code, /revoke all on function public\.client_records_stamp_swap\(\) from public, anon, authenticated/);
});
