import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { moderationAlert } from "./moderationAlert.mjs";

test("a report alert names the category and open count only", () => {
  const a = moderationAlert({ kind: "report", category: "message, harassment", openReports: 2 });
  assert.equal(a.title, "A report needs review");
  assert.match(a.body, /\(message, harassment\)/);
  assert.match(a.body, /Open reports: 2\./);
});

test("odd characters in the category are dropped", () => {
  const a = moderationAlert({ kind: "report", category: "spam <script>@x.com", openReports: 0 });
  assert.doesNotMatch(a.body, /[<>@.]x/);
});

test("a block alert has no details about who", () => {
  const a = moderationAlert({ kind: "block", openReports: 1 });
  assert.equal(a.title, "A member blocked someone");
});

test("the function only alerts about the caller's own recent row, and never texts", () => {
  const src = readFileSync(new URL("../notify-moderation/index.ts", import.meta.url), "utf8");
  assert.match(src, /eq\("reporter_id", user\.id\)/);
  assert.match(src, /eq\("blocker_id", user\.id\)/);
  assert.doesNotMatch(src, /sendSms|sendAutoSms/);
  assert.doesNotMatch(src, /content_excerpt/);
});
