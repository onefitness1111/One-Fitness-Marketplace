import assert from "node:assert/strict";
import test from "node:test";
import {
  INVITE_SMS_BODY,
  INVITE_SMS_VERSION,
  inviteConsentRecord,
  isInviteYes,
  staffClientSmsAction,
} from "./smsInvite.mjs";

test("the invite is one plain sentence and does not name a person", () => {
  assert.equal(
    INVITE_SMS_BODY,
    "ONE Fitness: Your coach sent you a message in the ONE Fitness app. Reply YES to receive it. Reply STOP to opt out.",
  );
});

test("YES, Y, yes!, and ok yes count, and a real sentence does not", () => {
  for (const text of ["YES", "yes", "Yes", "Y", "y", "yes!", "YES!", "ok yes", "OK YES", "ok  yes", "ok yes!"]) {
    assert.equal(isInviteYes(text), true, text);
  }
  for (const text of ["yes please", "yesterday", "yep", "ok, yes", "okay yes", "YES I can", "not now", ""]) {
    assert.equal(isInviteYes(text), false, text);
  }
});

test("a YES stores the reply, the invite wording, and the version", () => {
  const record = inviteConsentRecord();
  assert.equal(record.startsWith("Replied YES to invite SMS. "), true);
  assert.equal(record.includes(INVITE_SMS_BODY), true);
  assert.equal(record.endsWith(`(v${INVITE_SMS_VERSION})`), true);
  const stored = inviteConsentRecord("ONE Fitness: older invite");
  assert.equal(stored.includes("older invite"), true);
  assert.equal(stored.includes(INVITE_SMS_BODY), false);
});

test("only someone who has never answered is invited", () => {
  const never = { phone: "5551234567", hasConsent: false, primaryTrainerId: "coach-a" };
  assert.equal(staffClientSmsAction(never), "invite");
  assert.equal(staffClientSmsAction({ ...never, primaryTrainerId: null }), "invite");
  assert.equal(staffClientSmsAction({ ...never, primaryTrainerId: "someone-else" }), "invite");
  assert.equal(staffClientSmsAction({ ...never, hasConsent: true }), "send");
  assert.equal(staffClientSmsAction({ ...never, inviteSentAt: "2026-11-21T23:00:00Z" }), "hold");
  assert.equal(staffClientSmsAction({ ...never, optedOut: true }), "skip");
  assert.equal(staffClientSmsAction({ ...never, declined: true, hasConsent: true }), "skip");
  assert.equal(staffClientSmsAction({ phone: "  ", hasConsent: false }), "skip");
});
