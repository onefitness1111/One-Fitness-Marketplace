import assert from "node:assert/strict";
import test from "node:test";
import { EMAIL_SIGNOFF, OWNER_DISPLAY_NAME, SMS_PREFIX, businessText } from "./businessName.mjs";
import { BUSINESS_NAME, HELP_TEXT } from "./chatRouting.mjs";
import { INVITE_SMS_BODY, INVITE_YES_CONFIRMATION } from "./smsInvite.mjs";

test("one owner name everywhere", () => {
  assert.equal(OWNER_DISPLAY_NAME, "ONE Fitness Marketplace");
  assert.equal(BUSINESS_NAME, OWNER_DISPLAY_NAME);
  assert.equal(SMS_PREFIX, "ONE Fitness Marketplace: ");
  assert.equal(EMAIL_SIGNOFF, "— ONE Fitness Marketplace");
  assert.ok(HELP_TEXT.startsWith(SMS_PREFIX));
  assert.ok(INVITE_SMS_BODY.startsWith(SMS_PREFIX));
  assert.ok(INVITE_YES_CONFIRMATION.startsWith(SMS_PREFIX));
});

test("businessText adds the prefix once", () => {
  assert.equal(businessText("Hi"), "ONE Fitness Marketplace: Hi");
  assert.equal(businessText("ONE Fitness Marketplace: Hi"), "ONE Fitness Marketplace: Hi");
});
