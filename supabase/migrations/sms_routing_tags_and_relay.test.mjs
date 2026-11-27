import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261127120000_sms_routing_tags_and_relay.sql", import.meta.url), "utf8");
const code = sql.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n");

test("an owner tag reaches the texter even when the message is in-app only", () => {
  assert.ok(code.includes("owner_tag := sender_role = 'owner'"));
  assert.ok(code.includes("and new.copied_from is null"));
  assert.ok(code.includes("if not has_sms and not client_to_staff and not owner_tag then"));
});

test("reply routes are one per client and readable only by the owner", () => {
  assert.ok(code.includes("client_id uuid primary key references public.profiles (id) on delete cascade"));
  assert.ok(code.includes("alter table public.sms_reply_routes enable row level security;"));
  assert.ok(code.includes("using ((select public.is_owner()));"));
});

test("no coach-assignment field is used", () => {
  assert.equal(code.includes("primary_trainer_id"), false);
});
