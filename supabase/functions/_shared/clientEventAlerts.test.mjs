import assert from "node:assert/strict";
import test from "node:test";
import {
  sameCoachName,
  CLIENT_ALERTS_PER_HOUR,
  buildAlert,
  callerTargetAllowed,
  classifyClientPush,
  formatWhen,
  isRecent,
  safeName,
} from "./clientEventAlerts.mjs";

const NOW = Date.parse("2026-11-22T18:00:00Z");
const ago = (min) => new Date(NOW - min * 60_000).toISOString();
const C = "client-1", COACH = "coach-1", OWNER = "owner-1";

test("the titles the 1.1.2 app sends map to events", () => {
  const k = (title, profileId = COACH) => classifyClientPush({ callerId: C, profileId, title }).kind;
  assert.equal(k("New booking"), "booking");
  assert.equal(k("Late cancel"), "cancel");
  assert.equal(k("Early cancel"), "cancel");
  assert.equal(k("New client", OWNER), "signup");
  assert.equal(k("Measurement logged", OWNER), "measurement");
  assert.equal(k("New nutrition program needed", OWNER), "intake");
  assert.equal(k("New training program needed", OWNER), "intake");
  assert.equal(k("Exercise swap"), "swap");
  assert.equal(classifyClientPush({ callerId: C, profileId: OWNER, title: "New nutrition program needed" }).intakeKind, "nutrition");
});

test("a client's notice to themself is a no-op, whatever the title", () => {
  for (const t of ["Welcome", "Measurement saved", "Booking confirmed", "anything"]) {
    assert.equal(classifyClientPush({ callerId: C, profileId: C, title: t }).kind, "self");
  }
});

test("unknown titles and blank ids are refused", () => {
  for (const t of ["Free money", "new booking", "", "New booking!", "exercise swap"]) {
    assert.equal(classifyClientPush({ callerId: C, profileId: COACH, title: t }).kind, null);
  }
  assert.equal(classifyClientPush({ callerId: "", profileId: COACH, title: "New booking" }).kind, null);
  assert.equal(classifyClientPush({ callerId: C, profileId: " ", title: "New booking" }).kind, null);
});

test("formatWhen matches the app wording", () => {
  assert.equal(formatWhen("2026-11-24", 600), "Tue, Nov 24 at 10:00 AM");
  assert.equal(formatWhen("2026-11-24", 750), "Tue, Nov 24 at 12:30 PM");
  assert.equal(formatWhen("2026-11-22", 0), "Sun, Nov 22 at 12:00 AM");
});

test("safeName is one short line and never blank", () => {
  assert.equal(safeName(""), "A client");
  assert.equal(safeName(null), "A client");
  assert.equal(safeName("Sam\nTaylor"), "Sam Taylor");
  assert.ok(safeName("x".repeat(200)).length <= 60);
});

test("isRecent", () => {
  assert.ok(isRecent(ago(1), NOW, 15));
  assert.ok(!isRecent(ago(16), NOW, 15));
  assert.ok(!isRecent(new Date(NOW + 5 * 60_000).toISOString(), NOW, 15));
  assert.ok(!isRecent("garbage", NOW, 15));
});

test("booking alert goes to the session's coach with server words only", () => {
  const a = buildAlert({ kind: "booking" }, {
    nowMs: NOW, clientName: "Sam",
    booking: { id: "b1", trainer_id: COACH, date: "2026-11-24", slot_min: 600, created_at: ago(2) },
  });
  assert.deepEqual(a.recipients, [COACH]);
  assert.equal(a.title, "New booking");
  assert.equal(a.body, "Sam booked Tue, Nov 24 at 10:00 AM.");
  assert.equal(a.ref, "booking:b1");
  assert.ok(callerTargetAllowed(a, COACH));
  assert.ok(!callerTargetAllowed(a, "someone-else"));
});

test("no recent booking, no alert", () => {
  assert.equal(buildAlert({ kind: "booking" }, { nowMs: NOW, booking: null }), null);
  assert.equal(buildAlert({ kind: "booking" }, {
    nowMs: NOW, booking: { id: "b1", trainer_id: COACH, date: "2026-11-24", slot_min: 600, created_at: ago(60) },
  }), null);
});

test("cancel alert takes late/early from the server record, not the app title", () => {
  const facts = (status) => ({
    nowMs: NOW,
    cancel: { booking_id: "b2", trainer_id: COACH, date: "2026-11-24", slot_min: 420, status, cancelled_at: ago(1) },
  });
  assert.equal(buildAlert({ kind: "cancel" }, facts("late-cancel")).title, "Late cancel");
  assert.equal(buildAlert({ kind: "cancel" }, facts("early-cancel")).title, "Early cancel");
  assert.equal(buildAlert({ kind: "cancel" }, facts("early-cancel")).body, "A client cancelled Tue, Nov 24 at 7:00 AM.");
  assert.equal(buildAlert({ kind: "cancel" }, { nowMs: NOW, cancel: { ...facts("x").cancel, cancelled_at: ago(30) } }), null);
});

test("sign-up alert goes to owners only, and only for a new account", () => {
  const a = buildAlert({ kind: "signup" }, { nowMs: NOW, clientName: "Sam", owners: [OWNER, OWNER], profileCreatedAt: ago(3) });
  assert.deepEqual(a.recipients, [OWNER]);
  assert.equal(a.body, "Sam signed up.");
  assert.equal(buildAlert({ kind: "signup" }, { nowMs: NOW, owners: [OWNER], profileCreatedAt: ago(60 * 48) }), null);
  assert.equal(buildAlert({ kind: "signup" }, { nowMs: NOW, owners: [], profileCreatedAt: ago(1) }), null);
});

test("measurement and intake alerts need a fresh record", () => {
  const m = buildAlert({ kind: "measurement" }, { nowMs: NOW, clientName: "Sam", owners: [OWNER], measurementAt: ago(1) });
  assert.equal(m.title, "Measurement logged");
  assert.equal(buildAlert({ kind: "measurement" }, { nowMs: NOW, owners: [OWNER], measurementAt: ago(20) }), null);
  const i = buildAlert({ kind: "intake" }, { nowMs: NOW, clientName: "Sam", owners: [OWNER], intakeFlag: { kind: "nutrition", flagged_at: ago(1) } });
  assert.equal(i.title, "New nutrition program needed");
  assert.equal(i.body, "Sam filed a new intake.");
  assert.equal(buildAlert({ kind: "intake" }, { nowMs: NOW, owners: [OWNER], intakeFlag: null }), null);
});

test("unknown kinds build nothing; hourly cap is small", () => {
  assert.equal(buildAlert({ kind: null }, { nowMs: NOW }), null);
  assert.equal(buildAlert({ kind: "self" }, { nowMs: NOW }), null);
  assert.ok(CLIENT_ALERTS_PER_HOUR > 0 && CLIENT_ALERTS_PER_HOUR <= 20);
});

import { readFileSync } from "node:fs";

test("send-push routes clients to the safe path; that path never texts", () => {
  const sendPush = readFileSync(new URL("../send-push/index.ts", import.meta.url), "utf8");
  const clientPath = readFileSync(new URL("./clientEventPush.ts", import.meta.url), "utf8");
  const clientBranch = sendPush.indexOf('role === "client"');
  assert.ok(clientBranch > 0 && clientBranch < sendPush.indexOf("memberById("), "client branch must come first");
  assert.ok(sendPush.indexOf("return json(result)") > clientBranch);
  assert.equal(clientPath.includes("smsClientIfOptedIn"), false);
  assert.equal(clientPath.includes("body.body"), false, "client words must never be sent");
  assert.equal(clientPath.includes("body.data"), false);
  assert.ok(clientPath.includes('.eq("client_id", callerId)'));
});

test("swap alert goes to the program's coach, with a count and no client words", () => {
  const facts = { nowMs: NOW, clientName: "Sam", owners: [OWNER], programCoachId: COACH,
    swap: { logId: "log-1", swapsAt: ago(2), count: 2 } };
  const a = buildAlert({ kind: "swap" }, facts);
  assert.deepEqual(a.recipients, [COACH]);
  assert.equal(a.title, "Exercise swap");
  assert.equal(a.body, "Sam swapped 2 exercises in today's workout. The program was not changed.");
  assert.equal(a.ref, `swap:log-1:${ago(2)}`);
  assert.equal(buildAlert({ kind: "swap" }, { ...facts, swap: { ...facts.swap, count: 1 } }).body,
    "Sam swapped 1 exercise in today's workout. The program was not changed.");
});

test("swap alert falls back to the owner when no coach matches the program", () => {
  const a = buildAlert({ kind: "swap" }, { nowMs: NOW, clientName: "Sam", owners: [OWNER],
    swap: { logId: "log-1", swapsAt: ago(1), count: 1 } });
  assert.deepEqual(a.recipients, [OWNER]);
});

test("swap alert needs a fresh stamped swap", () => {
  const base = { nowMs: NOW, owners: [OWNER] };
  assert.equal(buildAlert({ kind: "swap" }, { ...base, swap: null }), null);
  assert.equal(buildAlert({ kind: "swap" }, { ...base, swap: { logId: "l", swapsAt: ago(30), count: 1 } }), null);
  assert.equal(buildAlert({ kind: "swap" }, { ...base, swap: { logId: "l", swapsAt: ago(1), count: 0 } }), null);
  assert.equal(buildAlert({ kind: "swap" }, { nowMs: NOW, owners: [], swap: { logId: "l", swapsAt: ago(1), count: 1 } }), null);
});

test("swap calls may target any staff member; other kinds only server recipients", () => {
  const swap = buildAlert({ kind: "swap" }, { nowMs: NOW, owners: [OWNER], swap: { logId: "l", swapsAt: ago(1), count: 1 } });
  assert.ok(callerTargetAllowed(swap, "any-coach", "coach"));
  assert.ok(callerTargetAllowed(swap, OWNER, "owner"));
  assert.ok(!callerTargetAllowed(swap, "a-client", "client"));
  assert.ok(!callerTargetAllowed(swap, "nobody", ""));
  const booking = buildAlert({ kind: "booking" }, { nowMs: NOW,
    booking: { id: "b", trainer_id: COACH, date: "2026-11-24", slot_min: 600, created_at: ago(1) } });
  assert.ok(!callerTargetAllowed(booking, "other-coach", "coach"));
});

test("coach-name match is exact, trimmed, case-insensitive, never blank", () => {
  assert.ok(sameCoachName(" Coach Chris ", "coach chris"));
  assert.ok(!sameCoachName("Coach Chris", "Coach Christine"));
  assert.ok(!sameCoachName("", ""));
  assert.ok(!sameCoachName(null, "Owner"));
});

test("the swap path reads only the caller's record and still never texts", () => {
  const clientPath = readFileSync(new URL("./clientEventPush.ts", import.meta.url), "utf8");
  const swap = clientPath.slice(clientPath.indexOf('case "swap"'), clientPath.indexOf("const alert = buildAlert"));
  assert.ok(swap.includes('.eq("profile_id", callerId)'));
  assert.equal(swap.includes("primary_trainer_id"), false);
  assert.equal(clientPath.includes("primary_trainer_id"), false);
});
