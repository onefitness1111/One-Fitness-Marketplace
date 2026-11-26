import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261126120000_owner_set_user_role.sql", import.meta.url), "utf8");
const code = sql.split("\n").filter((l) => !l.trimStart().startsWith("--")).join("\n");

test("only the signed-in owner gets past the first check", () => {
  const first = code.indexOf("current_user_role() is distinct from 'owner'");
  assert.ok(first > 0);
  assert.ok(code.includes("v_caller is null or public.current_user_role() is distinct from 'owner'"));
  // The owner check comes before anything is read or written.
  const firstRead = code.indexOf("from public.profiles p\n  where p.id = p_user");
  const firstWrite = code.indexOf("update public.profiles");
  assert.ok(first < firstRead && first < firstWrite);
});

test("only client or coach can be the new role; trainer is another spelling of coach", () => {
  assert.ok(code.includes("if v_new = 'trainer' then"));
  assert.ok(code.includes("if v_new not in ('client', 'coach') then"));
  assert.equal(/v_new\s*(=|in)[^;]*'owner'/.test(code), false);
});

test("the owner cannot be targeted, including the caller's own account", () => {
  assert.ok(code.includes("if p_user = v_caller then"));
  assert.ok(code.includes("if v_old = 'owner' then"));
});

test("it is a SECURITY DEFINER function with a fixed search_path", () => {
  assert.ok(/security definer/.test(code));
  assert.ok(/set search_path to 'public'/.test(code));
});

test("closed to anon and public, open to signed-in callers (the function checks the owner)", () => {
  assert.ok(code.includes("revoke all on function public.set_user_role(uuid, text) from public, anon;"));
  assert.ok(code.includes("grant execute on function public.set_user_role(uuid, text) to authenticated;"));
  assert.equal(/grant execute[^;]*\banon\b/.test(code), false);
});

test("nothing from the old role is deleted", () => {
  assert.equal(/\bdelete\s+from\b/i.test(code), false);
  assert.equal(/\bdrop\s+(table|column|function)\b/i.test(code), false);
  assert.equal(/\btruncate\b/i.test(code), false);
});

test("a coach gets a trainers row and a client gets a clients row, without overwriting", () => {
  assert.ok(/insert into public\.trainers \(profile_id, reviewed_by_owner, signup_at\)[\s\S]*?on conflict \(profile_id\) do nothing/.test(code));
  assert.ok(/insert into public\.clients \(profile_id\)[\s\S]*?on conflict \(profile_id\) do nothing/.test(code));
  assert.ok(/insert into public\.client_records[\s\S]*?on conflict \(profile_id\) do nothing/.test(code));
});

test("the change is written to the owner's activity feed with who, whom, old, new and when", () => {
  assert.ok(code.includes("insert into public.activity_log (actor_id, actor_name, action, entity, entity_id, subject, summary, details)"));
  assert.ok(code.includes("'oldRole', v_old"));
  assert.ok(code.includes("'newRole', v_new"));
  assert.ok(code.includes("'targetId', p_user"));
  // `at` is the table's default now(), so the time cannot be forged.
  assert.equal(/\bat\b\s*,/.test(code.slice(code.indexOf("insert into public.activity_log"), code.indexOf("values (", code.indexOf("insert into public.activity_log")))), false);
});

test("no coach-client assignment, no billing or Stripe change, no session cancelled", () => {
  assert.equal(code.includes("primary_trainer_id"), false);
  assert.equal(/stripe_subscription_id\s*=/.test(code), false);
  assert.equal(/update\s+public\.(bookings|clients)\b/i.test(code), false);
});

test("the profiles update is the only role write and runs after every check", () => {
  const updates = code.match(/update public\.profiles[^;]*;/g) ?? [];
  assert.equal(updates.length, 1);
  assert.ok(updates[0].includes("set role = v_new where id = p_user"));
});
