// Guards for the edge functions copied from the live project (L9).
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";

const root = new URL("../", import.meta.url);
const read = (rel) => readFileSync(new URL(rel, root), "utf8");
const code = (rel) => read(rel).split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");

const LIVE_ONLY = [
  "admin-cancel-membership", "admin-reset-mfa", "cancel-membership", "cancel-session",
  "challenge-leaderboard", "change-billing-anchor", "check-gym-citizen-expiry",
  "create-balance-payment", "create-client-account", "create-product-payment",
  "deduct-points", "delete-account", "delete-coach-account", "grant-points",
  "notify-waitlist-joined", "offer-waitlist-slot", "owner-subscription-terms",
  "photo-pilot-upload", "preview-billing-anchor-change", "redeem-points", "refund-charge",
  "register-device-token", "respond-waitlist-offer", "revoke-merit-badge",
  "send-booking-confirmation", "send-scheduled-reminders", "send-welcome-email",
  "sign-waiver", "sweep-expired-points", "void-points", "waitlist-sweep", "waive-charge",
];

test("every live-only function has its source in the repo", () => {
  for (const slug of LIVE_ONLY) {
    assert.ok(existsSync(new URL(`${slug}/index.ts`, root)), slug);
  }
  const manifest = read("LIVE_ONLY_FUNCTIONS.md");
  for (const slug of LIVE_ONLY) assert.match(manifest, new RegExp(`\\| ${slug} \\|`), slug);
});

test("no secrets or env values were copied in", () => {
  const secret = /sk_(live|test)_[A-Za-z0-9]|rk_live_|whsec_[A-Za-z0-9]|eyJ[A-Za-z0-9_-]{20,}\.|AC[0-9a-f]{32}/;
  for (const slug of LIVE_ONLY) assert.doesNotMatch(read(`${slug}/index.ts`), secret, slug);
});

test("no copied function assigns or reads a coach assignment (primary_trainer_id)", () => {
  // delete-account / delete-coach-account only CLEAR the column so a deleted
  // coach leaves no dangling reference (the FK is NO ACTION).
  const clearOnly = new Set(["delete-account", "delete-coach-account"]);
  for (const slug of LIVE_ONLY) {
    const src = code(`${slug}/index.ts`);
    if (clearOnly.has(slug)) {
      for (const m of src.matchAll(/primary_trainer_id[^\n]*/g)) {
        assert.match(m[0], /primary_trainer_id: null|\.eq\("primary_trainer_id"/, `${slug}: ${m[0]}`);
      }
      continue;
    }
    assert.doesNotMatch(src, /primary_trainer_id|primaryTrainerId/, slug);
  }
});

test("TCPA: nothing texts a client without an explicit opt-in", () => {
  const files = [
    ...readdirSync(new URL(".", import.meta.url)).filter((f) => /\.(ts|mjs)$/.test(f) && !f.endsWith(".test.mjs")).map((f) => `_shared/${f}`),
    ...LIVE_ONLY.map((s) => `${s}/index.ts`),
  ];
  for (const f of files) assert.doesNotMatch(code(f), /sms_opt_in\s*!==\s*false/, f);
  const offers = code("_shared/waitlistOffers.ts");
  assert.match(offers, /smsClientIfOptedIn\(/);
  assert.doesNotMatch(offers, /sendSms\(/);
  // notifySms hands off to sendAutoSms, whose rule needs an explicit
  // opt-in and no STOP (autoSmsRules.mjs).
  const rules = code("_shared/autoSmsRules.mjs");
  assert.match(rules, /smsOptIn !== true\) return "skip: not opted in"/);
  assert.match(rules, /optedOut === true\) return "skip: replied STOP"/);
  const auto = code("_shared/autoSms.ts");
  assert.match(auto, /sms_opt_in === true/);
  assert.match(auto, /sms_opted_out === true/);
  assert.match(code("_shared/notifySms.ts"), /sendAutoSms\(/);
  assert.match(code("notify-waitlist-joined/index.ts"), /sms_opt_in === true && profile\?\.sms_opted_out !== true/);
  assert.match(code("send-scheduled-reminders/index.ts"), /sms_opted_out === true\) return/);
});

test("redeem-points: one redemption is 40..100 points", () => {
  const src = code("redeem-points/index.ts");
  assert.match(src, /planRedemption\(lots, new Date\(\), \{ capPoints: 100, minPoints: 40 \}\)/);
  assert.match(src, /minimum of 40 points/);
});

test("AI stays owner-only: no copied function exposes AI features", () => {
  for (const slug of LIVE_ONLY) {
    assert.doesNotMatch(code(`${slug}/index.ts`), /openai|anthropic|\bgpt-|\bAI\b/, slug);
  }
});

test("coaches never get a client's phone back from create-client-account", () => {
  const src = code("create-client-account/index.ts");
  const response = src.slice(src.indexOf("JSON.stringify({ ok: true"));
  assert.doesNotMatch(response.slice(0, 200), /phone/);
});

test("sendEmail accepts an HTML body or attachments, and HTML-only sends", () => {
  const src = code("_shared/sendEmail.ts");
  assert.match(src, /export type EmailAttachment/);
  assert.match(src, /export async function sendHtmlEmailOrThrow/);
  assert.match(src, /htmlOrAttachments\?: string \| EmailAttachment\[\]/);
});
