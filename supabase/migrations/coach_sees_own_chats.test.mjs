import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261127140000_coach_sees_own_chats.sql", import.meta.url), "utf8");
const policy = (name) => {
  const start = sql.indexOf(`create policy ${name} `);
  assert.ok(start >= 0, name);
  return sql.slice(start, sql.indexOf(";", start));
};

test("a coach no longer reads every message", () => {
  const select = policy("messages_select");
  assert.doesNotMatch(select, /in \('coach', 'owner'\)/);
  assert.match(select, /trainer_id = \(select auth\.uid\(\)\)/);
  assert.match(select, /public\.is_owner\(\)/);
  assert.match(select, /from public\.blocks/);
});

test("a coach writes only into their own thread", () => {
  const insert = policy("messages_insert");
  assert.match(insert, /who = 'trainer'\s+and trainer_id = \(select auth\.uid\(\)\)/);
});

test("conversations and likes follow the same rule", () => {
  assert.doesNotMatch(policy("conversations_select"), /'coach'/);
  assert.doesNotMatch(policy("reactions_select"), /'coach'/);
  assert.doesNotMatch(policy("reactions_insert"), /'coach'/);
});

test("never keyed on primary_trainer_id", () => {
  assert.doesNotMatch(sql.replace(/^--.*$/gm, ""), /primary_trainer_id/);
});
