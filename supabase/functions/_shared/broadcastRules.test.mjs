import assert from "node:assert/strict";
import test from "node:test";
import {
  broadcastChannel,
  broadcastSummaryChannel,
  broadcastWays,
  previewBroadcast,
  sanitizeGroupName,
  scopeBroadcast,
  smsQuietHours,
} from "./broadcastRules.mjs";

const clients = [
  { id: "a", primaryTrainerId: "chris", phone: "5551112222", email: "a@gym.test", smsOptIn: true },
  { id: "b", primaryTrainerId: "chris", phone: "", email: "b@gym.test", smsOptIn: false },
  { id: "c", primaryTrainerId: "pat", phone: "5553334444", email: "c@gym.test", smsOptIn: true },
];

test("any mix of in app, text, and email is allowed, and empty is not", () => {
  assert.deepEqual(broadcastWays(["inapp"]), { app: true, sms: false, email: false });
  assert.deepEqual(broadcastWays(["sms", "inapp"]), { app: true, sms: true, email: false });
  assert.deepEqual(broadcastWays(["email", "inapp"]), { app: true, sms: false, email: true });
  assert.deepEqual(broadcastWays(["inapp", "sms", "email"]), { app: true, sms: true, email: true });
  assert.equal(broadcastWays([]), null);
  assert.deepEqual(broadcastWays({ channel: "app_sms" }), { app: true, sms: true, email: false });
  assert.equal(broadcastChannel("sms"), null);
  assert.equal(broadcastChannel("app_sms"), "app_sms");
  assert.equal(broadcastSummaryChannel({ app: true, sms: false, email: false }), "app");
  assert.equal(broadcastSummaryChannel({ app: true, sms: true, email: false }), "app_sms");
  assert.equal(broadcastSummaryChannel({ app: false, sms: false, email: true }), "email");
  assert.equal(broadcastSummaryChannel({ app: true, sms: true, email: true }), "inapp,sms,email");
  assert.equal(sanitizeGroupName("  Morning\ncrew  "), "Morning crew");
  assert.equal(sanitizeGroupName("x".repeat(50)).length, 40);
  assert.equal(sanitizeGroupName(" \n "), "");
});

test("a coach reaches every client", () => {
  const own = scopeBroadcast({ senderIsOwner: false, senderId: "chris", all: true, clients });
  assert.deepEqual(own.allowed.map((c) => c.id), ["a", "b", "c"]);
  const picked = scopeBroadcast({
    senderIsOwner: false,
    senderId: "chris",
    all: false,
    requestedIds: ["a", "c"],
    clients,
  });
  assert.deepEqual(picked.allowed.map((c) => c.id), ["a", "c"]);
  assert.deepEqual(picked.refused, []);
});

test("the owner reaches every client", () => {
  const everyone = scopeBroadcast({
    senderIsOwner: true,
    senderId: "owner",
    all: false,
    requestedIds: ["a", "c"],
    clients,
  });
  assert.deepEqual(everyone.allowed.map((c) => c.id), ["a", "c"]);
  assert.deepEqual(everyone.refused, []);
});

test("quiet hours are before 8am and from 9pm Pacific", () => {
  assert.equal(smsQuietHours(new Date("2026-01-15T15:00:00Z")), true);
  assert.equal(smsQuietHours(new Date("2026-01-15T16:00:00Z")), false);
  assert.equal(smsQuietHours(new Date("2026-07-15T03:59:00Z")), false);
  assert.equal(smsQuietHours(new Date("2026-07-15T04:00:00Z")), true);
});

test("the preview skips a missing phone, an opt-out, and a missing email", () => {
  const text = previewBroadcast({
    ways: { app: true, sms: true },
    recipients: clients.filter((c) => c.primaryTrainerId === "chris"),
    now: new Date("2026-01-15T18:00:00Z"),
  });
  assert.equal(text.app, 2);
  assert.equal(text.sms, 1);
  assert.equal(text.skippedNoPhone, 1);

  const stopped = previewBroadcast({
    ways: { app: true, sms: true },
    recipients: [{ id: "a", phone: "555", smsOptIn: true, smsOptedOut: true }],
    now: new Date("2026-07-15T20:00:00Z"),
  });
  assert.equal(stopped.app, 1);
  assert.equal(stopped.sms, 0);
  assert.equal(stopped.skippedOptOut, 1);
});
