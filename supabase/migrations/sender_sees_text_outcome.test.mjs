import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync(new URL("./20261127150000_sender_sees_text_outcome.sql", import.meta.url), "utf8");

test("only the sender (or the owner) reads a message's text outcome", () => {
  assert.match(sql, /for select to authenticated/);
  assert.match(sql, /m\.sender_id = \(select auth\.uid\(\)\)/);
  assert.match(sql, /public\.is_owner\(\)/);
  assert.doesNotMatch(sql, /for (insert|update|delete|all)/);
});
