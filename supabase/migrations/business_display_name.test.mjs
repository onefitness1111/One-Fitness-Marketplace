import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { OWNER_DISPLAY_NAME } from "../functions/_shared/businessName.mjs";

const sql = readFileSync(new URL("./20261127100000_business_display_name.sql", import.meta.url), "utf8");
const dart = readFileSync(new URL("../../lib/core/utils/chat_channels.dart", import.meta.url), "utf8");

test("database, app and functions use the same business name", () => {
  assert.ok(sql.includes(`select '${OWNER_DISPLAY_NAME}'::text;`));
  assert.ok(dart.includes(`const kMarketplaceName = "${OWNER_DISPLAY_NAME}";`));
  assert.ok(sql.includes("return public.business_display_name();"));
});

test("no coach-assignment field is used", () => {
  assert.equal(sql.includes("primary_trainer_id"), false);
});
