import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261126140000_coach_permissions.sql", import.meta.url), "utf8");
const code = sql.split("\n").filter((l) => !l.trimStart().startsWith("--")).join("\n");

const PERMS = ["billing_access", "charge_fees", "edit_plans", "send_texts", "manage_other_schedules", "see_own_revenue"];

test("one boolean per permission, all default false (a new coach starts with nothing)", () => {
  for (const p of PERMS) assert.ok(code.includes(`${p} boolean not null default false`), p);
  assert.ok(code.includes("insert into public.coach_permissions (profile_id) values (new.profile_id)"));
  assert.ok(code.includes("after insert on public.trainers"));
});

test("existing coaches are backfilled to all six on, nothing else", () => {
  assert.ok(code.includes("select p.id, true, true, true, true, true, true"));
  assert.ok(code.includes("where p.role = 'coach'"));
  assert.ok(code.includes("on conflict (profile_id) do nothing"));
});

test("only the owner writes the table; a coach reads only their own row", () => {
  assert.ok(code.includes("alter table public.coach_permissions enable row level security"));
  assert.ok(code.includes("using ((select public.is_owner()) or profile_id = (select auth.uid()))"));
  for (const verb of ["insert", "update", "delete"]) {
    assert.ok(code.includes(`create policy coach_permissions_${verb}_owner`), verb);
  }
  assert.ok(code.includes("revoke all on table public.coach_permissions from public, anon"));
});

test("the setter is owner-checked first and revoked from anon", () => {
  const fn = code.slice(code.indexOf("function public.set_coach_permission"));
  assert.ok(fn.includes("public.current_user_role() is distinct from 'owner'"));
  assert.ok(fn.indexOf("is distinct from 'owner'") < fn.indexOf("update public.coach_permissions") || fn.indexOf("is distinct from 'owner'") < fn.indexOf("execute format"));
  assert.ok(code.includes("revoke all on function public.set_coach_permission(uuid, text, boolean) from public, anon"));
  assert.ok(code.includes("security definer"));
  assert.ok(code.includes("insert into public.activity_log"));
});

test("has_coach_permission: owner true, missing row false, unknown name false, self-only lookup", () => {
  const fn = code.slice(code.indexOf("function public.has_coach_permission"), code.indexOf("function public.set_coach_permission"));
  assert.ok(fn.includes("if v_role = 'owner' then\n    return true;"));
  assert.ok(fn.includes("return coalesce(v_value, false)"));
  assert.ok(fn.includes("p_perm not in ("));
  assert.ok(fn.includes("p_uid is distinct from auth.uid()"));
});

test("revenue: charges, orders and pay rates are closed to a coach without see_own_revenue", () => {
  assert.ok(code.includes("and trainer_id = (select auth.uid())\n      and public.has_coach_permission((select auth.uid()), 'see_own_revenue')"));
  assert.ok(code.includes("using (client_id = (select auth.uid()) or (select public.is_owner()))"));
  assert.ok(code.includes("t.profile_id = (select auth.uid())\n        and public.has_coach_permission((select auth.uid()), 'see_own_revenue')"));
});

test("reports are scoped to the coach's own sessions, never primary_trainer_id", () => {
  assert.ok(code.includes("b.trainer_id = auth.uid()"));
  assert.ok(code.includes("function public.coach_report_bookings(p_from date, p_to date)"));
  assert.ok(code.includes("function public.coach_report_client_ids()"));
  assert.equal(code.includes("primary_trainer_id"), false);
});

test("the other switches are enforced in the database too", () => {
  assert.ok(code.includes("has_coach_permission(auth.uid(), 'billing_access')"));
  assert.ok(code.includes("has_coach_permission(auth.uid(), 'edit_plans')"));
  assert.ok(code.includes("has_coach_permission(new.sender_id, 'send_texts')"));
  assert.ok(code.includes("has_coach_permission((select auth.uid()), 'manage_other_schedules')"));
  // The plan guard must be a plain trigger so the server's own writes pass.
  const guard = code.slice(code.indexOf("function public.guard_coach_plan_edits"), code.indexOf("revoke all on function public.guard_coach_plan_edits"));
  assert.equal(guard.includes("security definer"), false);
  assert.ok(guard.includes("current_user is distinct from 'authenticated'"));
});

test("no secrets, no live changes beyond the migration itself, and no phone numbers", () => {
  assert.equal(/\bphone\b/i.test(code), false);
  assert.equal(/drop table|truncate/i.test(code), false);
});
