import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261123020000_revoke_temp_select_least_privilege.sql", import.meta.url), "utf8");
const dart = readFileSync(new URL("../../lib/core/supabase/supabase_service.dart", import.meta.url), "utf8");
const dash = readFileSync(new URL("../../lib/data/providers/dashboard_load.dart", import.meta.url), "utf8");

const code = sql.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n");
const list = (s) => s.split(",").map((c) => c.trim()).filter(Boolean);
function granted(table) {
  const m = new RegExp(`grant select \\(([^)]*)\\) on public\\.${table} to authenticated`).exec(code);
  assert.ok(m, `no column grant for ${table}`);
  return new Set(list(m[1]));
}
function dartConst(src, name) {
  const m = new RegExp(`${name}\\s*=\\s*"([^"]+)"`).exec(src);
  assert.ok(m, `missing ${name}`);
  return list(m[1]);
}

test("the whole-table read is revoked from every API role", () => {
  assert.match(code, /revoke select on table public\.profiles, public\.clients, public\.trainers from public, anon, authenticated/);
  assert.doesNotMatch(code, /grant select on table public\.(profiles|clients|trainers)/);
  assert.doesNotMatch(code, /to anon/);
});

test("every column the app selects stays readable", () => {
  const clients = granted("clients");
  const trainers = granted("trainers");
  const profiles = granted("profiles");
  for (const c of dartConst(dart, "_clientColumns")) assert.ok(clients.has(c), `clients.${c}`);
  for (const c of dartConst(dart, "_trainerColumns")) assert.ok(trainers.has(c), `trainers.${c}`);
  for (const c of dartConst(dash, "dashboardTrainerColumns")) assert.ok(trainers.has(c), `trainers.${c}`);
  for (const c of ["accepted_terms_at", "accepted_terms_version", "id", "role"]) assert.ok(profiles.has(c), `profiles.${c}`);
  assert.ok(clients.has("sms_opt_in"));
  assert.ok(trainers.has("coach_code"));
});

test("private columns are never granted", () => {
  const banned = {
    profiles: ["name", "first_name", "last_name", "email", "phone", "calendar_token", "sms_consent_at", "sms_consent_text", "sms_opted_out"],
    clients: ["billing_address", "emergency_contact_phone", "stripe_customer_id", "stripe_subscription_id", "stripe_schedule_id",
      "balance_cents", "grace_booking_used", "outstanding_invoice_url", "outstanding_balance_cents", "sms_invite_text"],
    trainers: ["commission_rate", "payout_mode", "payout_rate_cents", "referral_commission_percent", "secondary_coach_name"],
  };
  for (const [table, cols] of Object.entries(banned)) {
    const g = granted(table);
    for (const c of cols) assert.ok(!g.has(c), `${table}.${c} must not be granted`);
  }
});

test("balance policies no longer read clients columns as the caller", () => {
  const policies = code.slice(code.indexOf("create policy bookings_block_negative_balance"), code.indexOf("revoke select on table"));
  assert.doesNotMatch(policies, /balance_cents|grace_booking_used/);
  assert.match(policies, /client_balance_ok\(client_id\)/);
  assert.match(code, /function public\.client_balance_ok[\s\S]*?security definer/);
  assert.match(code, /function public\.client_grace_unused[\s\S]*?security definer/);
  assert.match(code, /revoke all on function public\.client_balance_ok\(uuid\) from public, anon/);
});
