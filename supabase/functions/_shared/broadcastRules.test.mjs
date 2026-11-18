import assert from "node:assert/strict";
import test from "node:test";
import {
  broadcastChannel,
  broadcastChannelFromSet,
  previewBroadcast,
  scopeBroadcast,
  smsQuietHours,
} from "./broadcastRules.mjs";

const clients = [
  { id: "a", primaryTrainerId: "chris", phone: "5551112222", email: "a@gym.test", smsOptIn: true },
  { id: "b", primaryTrainerId: "chris", phone: "", email: "b@gym.test", smsOptIn: false },
  { id: "c", primaryTrainerId: "pat", phone: "5553334444", email: "c@gym.test", smsOptIn: true },
];

test("only app, app plus text, or email alone are allowed", () => {
  assert.equal(broadcastChannelFromSet(["inapp"]), "app");
  assert.equal(broadcastChannelFromSet(["sms", "inapp"]), "app_sms");
  assert.equal(broadcastChannelFromSet(["email"]), "email");
  assert.equal(broadcastChannelFromSet(["sms"]), null);
  assert.equal(broadcastChannelFromSet(["email", "inapp"]), null);
  assert.equal(broadcastChannelFromSet(["email", "sms"]), null);
  assert.equal(broadcastChannelFromSet(["inapp", "sms", "email"]), null);
  assert.equal(broadcastChannel("sms"), null);
  assert.equal(broadcastChannel("app_sms"), "app_sms");
});

test("a coach reaches only their own clients", () => {
  const own = scopeBroadcast({ senderIsOwner: false, senderId: "chris", all: true, clients });
  assert.deepEqual(own.allowed.map((c) => c.id), ["a", "b"]);
  const picked = scopeBroadcast({
    senderIsOwner: false,
    senderId: "chris",
    all: false,
    requestedIds: ["a", "c"],
    clients,
  });
  assert.deepEqual(picked.allowed.map((c) => c.id), ["a"]);
  assert.deepEqual(picked.refused, ["c"]);
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
    channel: "app_sms",
    recipients: clients.filter((c) => c.primaryTrainerId === "chris"),
    now: new Date("2026-01-15T18:00:00Z"),
  });
  assert.equal(text.app, 2);
  assert.equal(text.sms, 1);
  assert.equal(text.skippedNoPhone, 1);

  const stopped = previewBroadcast({
    channel: "app_sms",
    recipients: [{ id: "a", phone: "555", smsOptIn: true, smsOptedOut: true }],
    now: new Date("2026-07-15T20:00:00Z"),
  });
  assert.equal(stopped.app, 1);
  assert.equal(stopped.sms, 0);
  assert.equal(stopped.skippedOptOut, 1);
});
