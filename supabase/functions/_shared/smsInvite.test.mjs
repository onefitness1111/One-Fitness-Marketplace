import assert from "node:assert/strict";
import test from "node:test";
import {
  INVITE_SMS_BODY,
  INVITE_SMS_VERSION,
  inviteConsentRecord,
  inviteEligible,
  isInviteYes,
  smsInviteEnabledFlag,
  staffClientSmsAction,
} from "./smsInvite.mjs";

test("the invite is one plain sentence and does not name a person", () => {
  assert.equal(
    INVITE_SMS_BODY,
    "ONE Fitness Marketplace: Your coach sent you a message in the ONE Fitness app. Reply YES to receive it. Reply STOP to opt out.",
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

test("only someone who has never answered is invited, and only when the flag is on", () => {
  const never = { phone: "5551234567", hasConsent: false, declined: false, optedOut: false };
  const on = { inviteEnabled: true };
  assert.equal(staffClientSmsAction(never), "disabled");
  assert.equal(inviteEligible(never), false);
  assert.equal(staffClientSmsAction(never, on), "invite");
  assert.equal(inviteEligible(never, on), true);
  assert.equal(staffClientSmsAction({ ...never, hasConsent: true }, on), "send");
  assert.equal(inviteEligible({ ...never, hasConsent: true }, on), false);
  assert.equal(staffClientSmsAction({ ...never, inviteSentAt: "2026-11-21T23:00:00Z" }, on), "hold");
  assert.equal(inviteEligible({ ...never, inviteSentAt: "2026-11-21T23:00:00Z" }, on), false);
  assert.equal(staffClientSmsAction({ ...never, optedOut: true }, on), "skip");
  assert.equal(staffClientSmsAction({ ...never, declined: true, hasConsent: true }, on), "skip");
  assert.equal(staffClientSmsAction({ ...never, declined: true }, on), "skip");
  assert.equal(staffClientSmsAction({ phone: "  ", hasConsent: false }, on), "skip");
});

test("the invite flag is on only when the stored value is boolean true", () => {
  assert.equal(smsInviteEnabledFlag(null), false);
  assert.equal(smsInviteEnabledFlag({}), false);
  assert.equal(smsInviteEnabledFlag({ sms_invite_enabled: false }), false);
  assert.equal(smsInviteEnabledFlag({ sms_invite_enabled: "true" }), false);
  assert.equal(smsInviteEnabledFlag({ sms_invite_enabled: 1 }), false);
  assert.equal(smsInviteEnabledFlag({ sms_invite_enabled: true }), true);
});
