import assert from "node:assert/strict";
import test from "node:test";
import { autoSmsDecision } from "./autoSmsRules.mjs";

const day = new Date("2026-11-27T20:00:00Z"); // noon Pacific
const night = new Date("2026-11-28T06:00:00Z"); // 10pm Pacific
const client = { role: "client", phone: "(818) 223-7001", smsOptIn: true, optedOut: false, declined: false };

test("an opted-in client is texted by day and queued at night", () => {
  assert.equal(autoSmsDecision(client, day), "send");
  assert.equal(autoSmsDecision(client, night), "defer");
});

test("TCPA: no consent, STOP, or texts turned off means no text", () => {
  assert.equal(autoSmsDecision({ ...client, smsOptIn: false }, day), "skip: not opted in");
  assert.equal(autoSmsDecision({ ...client, optedOut: true }, day), "skip: replied STOP");
  assert.equal(autoSmsDecision({ ...client, declined: true }, day), "skip: turned texts off");
  assert.equal(autoSmsDecision({ ...client, optedOut: true }, night), "skip: replied STOP");
});

test("made-up and unreachable numbers are skipped", () => {
  assert.equal(autoSmsDecision({ ...client, phone: "1234567890" }, day), "skip: not a textable number");
  assert.equal(autoSmsDecision({ ...client, phone: "" }, day), "skip: no phone");
  assert.equal(autoSmsDecision({ ...client, undeliverable: true }, day), "skip: number can't get texts");
});

test("staff need only a phone and no STOP", () => {
  assert.equal(autoSmsDecision({ role: "coach", phone: "8182237001" }, day), "send");
  assert.equal(autoSmsDecision({ role: "owner", phone: "8182237001", optedOut: true }, day), "skip: replied STOP");
});
