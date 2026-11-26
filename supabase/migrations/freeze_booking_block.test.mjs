import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261125120000_freeze_booking_block_and_held_sessions.sql", import.meta.url), "utf8");

function fnBody(name) {
  const start = sql.indexOf(`create or replace function public.${name}(`);
  assert.ok(start >= 0, `${name} is missing`);
  const next = sql.indexOf("create or replace function public.", start + 1);
  return sql.slice(start, next < 0 ? sql.length : next);
}

test("C6: every booking insert and every date move is checked", () => {
  assert.ok(sql.includes("create trigger block_frozen_client_booking\n  before insert or update of date, client_id, cancelled_at\n  on public.bookings"));
  assert.ok(sql.includes("drop trigger if exists block_frozen_client_booking on public.bookings;"));
});

test("C6: only the owner skips the freeze check; coaches and edge functions do not", () => {
  const body = fnBody("block_frozen_client_booking");
  assert.ok(body.includes("auth.role() is distinct from 'service_role'\n     and public.current_user_role() = 'owner'"));
  assert.equal(body.includes("'coach'"), false);
});

test("U14: the client is told when the freeze ends and that they can book that day", () => {
  const body = fnBody("block_frozen_client_booking");
  assert.ok(body.includes("'Your account is frozen until %s. You can book sessions starting that day.'"));
  assert.ok(body.includes("to_char(until_day, 'FMMon FMDD')"));
});

test("the freeze window covers the start day and stops before the end day", () => {
  const body = fnBody("client_frozen_until");
  assert.ok(body.includes("(from_day is null or p_day >= from_day)"));
  assert.ok(body.includes("(until_day is null or p_day < until_day)"));
  // Approved coach requests that have not started yet block too.
  assert.ok(body.includes("r.status = 'approved'"));
  assert.ok(body.includes("r.applied_at is null"));
});

test("nothing is gated on primary_trainer_id", () => {
  assert.equal(sql.includes("primary_trainer_id"), false);
});

test("held sessions: unlimited plans stay unlimited and coaches keep booking past limits", () => {
  const allowance = fnBody("client_plan_allowance");
  assert.ok(allowance.includes("if kind = 'membership' and limited then"));
  assert.ok(allowance.includes("return greatest(h_held, 0) + rollover;"));
  // The allowance trigger (and its staff skip) is not replaced here.
  assert.equal(sql.includes("enforce_client_session_allowance"), false);
});

test("the monthly count leaves out bookings in the held window", () => {
  const body = fnBody("sessions_toward_booking_limit");
  assert.ok(body.includes("(in_hold and b.date >= h_from and b.date < h_until)"));
  assert.ok(body.includes("and not (h_from is not null and b.date >= h_from and b.date < h_until)"));
});
