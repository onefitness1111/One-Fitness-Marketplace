import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

function read(name) {
  return readFileSync(new URL(name, import.meta.url), "utf8");
}

function withoutLineComments(sql) {
  return sql.replace(/--.*$/gm, "");
}

test("the rollover move runs as service_role and reports how many moved", () => {
  const sql = read("./20261122120000_membership_rollover.sql");
  assert.match(sql, /set_config\('request\.jwt\.claims', '\{"role":"service_role"\}', true\)/);
  assert.match(sql, /set_config\('request\.jwt\.claim\.role', 'service_role', true\)/);
  assert.match(sql, /raise notice 'membership rollover: moved % session_count_override/);
  assert.match(sql, /where session_count_override is not null/);
});

test("a client can select a ghost plan they hold, and the helper is security definer", () => {
  const sql = read("./20261122140000_plan_visibility_status.sql");
  const policy = sql.slice(sql.indexOf("create policy membership_plans_select_authenticated"));
  assert.match(policy, /client_holds_plan\(auth\.uid\(\), id\)/);
  assert.match(policy, /plan_visibility\(data\) is distinct from 'ghost'/);
  const helper = sql.slice(sql.indexOf("create or replace function public.client_holds_plan"));
  assert.match(helper, /security definer/);
  assert.match(helper, /stable/);
});

test("turning texts off records a decline, and invites stay off by default", () => {
  const sql = read("./20261121230000_sms_invite_hold.sql");
  assert.match(sql, /old\.sms_opt_in is true/);
  assert.match(sql, /new\.sms_declined_at := now\(\)/);
  assert.match(sql, /new\.sms_opted_out is true/);
  assert.match(sql, /sms_invite_enabled boolean not null default false/);
  assert.match(sql, /sms_invite_review\.sql/);
  assert.equal(sql.includes("sms_declined_at = now()") || sql.includes("sms_declined_at := now()"), true);
});

test("the invite review file is a select and does not change rows", () => {
  const sql = read("../sms_invite_review.sql");
  const body = withoutLineComments(sql);
  assert.equal(/\b(insert|update|delete|alter|drop|truncate)\b/i.test(body), false);
  assert.match(sql, /sms_declined_at is null/);
  assert.match(sql, /sms_invite_sent_at is null/);
  assert.match(sql, /sms_opted_out is not true/);
  assert.match(sql, /sms_opt_in is not true/);
  assert.match(sql, /sms_consent_at is null/);
  assert.match(sql, /sms_invite_enabled/);
});

test("gateway JWT checks match the live webhook and cron functions", () => {
  const toml = read("../config.toml");
  for (const name of ["chat-auto-reply-sms", "sms-inbound", "twilio-inbound", "rollover-membership-sessions"]) {
    const start = toml.indexOf(`[functions.${name}]`);
    assert.ok(start >= 0, name);
    const line = toml.slice(start, start + 500).match(/verify_jwt = (true|false)/);
    assert.equal(line?.[1], "false", name);
  }
});
