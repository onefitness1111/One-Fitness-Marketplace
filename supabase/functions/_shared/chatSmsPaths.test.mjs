import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

function source(name) {
  return readFileSync(new URL(name, import.meta.url), "utf8");
}

test("chat-auto-reply-sms texts the client when staff reply, and gates invites", () => {
  const auto = source("../chat-auto-reply-sms/index.ts");
  assert.equal(auto.includes("function recipientId"), false);
  assert.match(auto, /smsRecipientId\(/);
  assert.match(auto, /loadSmsInviteEnabled/);
  assert.match(auto, /held: invites off/);
  assert.equal(auto.includes("INVITE_SMS_BODY"), true);
});

test("client-notify does not choose an SMS recipient from trainer_id", () => {
  const notify = source("../client-notify/index.ts");
  assert.equal(notify.includes("recipientId"), false);
  assert.equal(notify.includes("smsRecipientId"), false);
  assert.match(notify, /kind === "chat-to-staff"/);
  assert.match(notify, /smsClientIfOptedIn/);
});

test("broadcast stores the sender as trainer_id and does not invite", () => {
  const broadcast = source("../broadcast-message/index.ts");
  assert.match(broadcast, /trainer_id: userId/);
  assert.match(broadcast, /sender_id: userId/);
  assert.equal(broadcast.includes("INVITE_SMS_BODY"), false);
  assert.equal(broadcast.includes("recipientId"), false);
});

test("send-sms does not send the consent invite", () => {
  const send = source("../send-sms/index.ts");
  assert.equal(send.includes("INVITE_SMS_BODY"), false);
  assert.match(send, /hasn't agreed to text messages yet/);
  assert.match(send, /sms_declined_at/);
});
