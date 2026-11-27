import assert from "node:assert/strict";
import test from "node:test";
import { deadPushToken } from "./pushErrors.mjs";

const fcm = (status, errorCode, message = "") =>
  JSON.stringify({ error: { code: status, message, details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode }] } });

test("unregistered and invalid tokens are dead", () => {
  assert.equal(deadPushToken(404, fcm(404, "UNREGISTERED", "Requested entity was not found.")), true);
  assert.equal(deadPushToken(400, fcm(400, "INVALID_ARGUMENT", "The registration token is not a valid FCM registration token")), true);
});

test("our own credential, quota and outages keep the token", () => {
  assert.equal(deadPushToken(401, fcm(401, "THIRD_PARTY_AUTH_ERROR", "Auth error from APNS or Web Push Service")), false);
  assert.equal(deadPushToken(429, fcm(429, "QUOTA_EXCEEDED")), false);
  assert.equal(deadPushToken(503, fcm(503, "UNAVAILABLE")), false);
  assert.equal(deadPushToken(400, fcm(400, "INVALID_ARGUMENT", "Invalid JSON payload received.")), false);
  assert.equal(deadPushToken(500, "not json"), false);
});
