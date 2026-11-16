import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { signTwilioWebhook } from "./sign-twilio-webhook.mjs";

const autoReply = await import("../supabase/functions/_shared/autoReply.ts");
const urls = await import("../supabase/functions/_shared/twilioWebhookUrl.ts");

const QUIET_MS = autoReply.AUTO_REPLY_QUIET_HOURS * 60 * 60 * 1000;

test("the database copy uses the same sentences and the same 6 hour window", () => {
  const sql = readFileSync(new URL("../supabase/migrations/20261116230000_chat_auto_reply.sql", import.meta.url), "utf8");
  assert.match(sql, /auto_reply_quiet_hours constant integer := 6/);
  assert.ok(sql.includes(autoReply.COACH_AUTO_REPLY.replaceAll("'", "''")));
  assert.ok(sql.includes(autoReply.BUSINESS_AUTO_REPLY.replaceAll("'", "''")));
  assert.match(sql, /new\.channel = 'sms'/);
  assert.match(sql, /who = 'auto'/);
});

test("quiet window is 6 hours and named once", () => {
  assert.equal(autoReply.AUTO_REPLY_QUIET_HOURS, 6);
  assert.match(autoReply.COACH_AUTO_REPLY, /your coach has received your message/);
  assert.match(autoReply.BUSINESS_AUTO_REPLY, /your message was received/);
  assert.equal(autoReply.COACH_AUTO_REPLY.includes("This number is monitored"), false);
});

test("auto-reply is skipped only while the last human reply is under 6 hours old", () => {
  const now = Date.parse("2026-11-16T22:00:00.000Z");
  assert.equal(autoReply.autoReplySuppressed(null, now), false);
  assert.equal(autoReply.autoReplySuppressed(new Date(now - QUIET_MS + 1).toISOString(), now), true);
  assert.equal(autoReply.autoReplySuppressed(new Date(now - 60 * 60 * 1000).toISOString(), now), true);
  assert.equal(autoReply.autoReplySuppressed(new Date(now - QUIET_MS).toISOString(), now), false);
  assert.equal(autoReply.autoReplySuppressed(new Date(now - QUIET_MS - 1).toISOString(), now), false);
  assert.equal(autoReply.autoReplySuppressed("not-a-time", now), false);
});

test("public /functions/v1 URL is a candidate when the runtime path drops it", () => {
  const candidates = urls.webhookCandidates({
    requestUrl: "http://supabase_edge_runtime/twilio-inbound?foo=1",
    forwardedHost: "rivhgutksyddeckieknc.supabase.co",
    host: "supabase_edge_runtime",
    override: null,
    supabaseUrl: "https://rivhgutksyddeckieknc.supabase.co",
  });
  assert.equal(candidates[0].includes("/functions/v1/twilio-inbound"), true);
  assert.ok(candidates.includes("https://rivhgutksyddeckieknc.supabase.co/functions/v1/twilio-inbound?foo=1"));
  assert.ok(candidates.includes("https://rivhgutksyddeckieknc.supabase.co/functions/v1/twilio-inbound"));
  assert.ok(candidates.includes("http://supabase_edge_runtime/twilio-inbound?foo=1"));
});

test("TWILIO_WEBHOOK_URL is checked first and is not printed in the log label", () => {
  const override = "https://example.supabase.co/functions/v1/twilio-inbound?secret=1";
  const candidates = urls.webhookCandidates({
    requestUrl: "http://internal/twilio-inbound",
    forwardedHost: "example.supabase.co",
    host: null,
    override,
    supabaseUrl: null,
  });
  assert.equal(candidates[0], override);
  assert.equal(urls.describeWebhookUrl(override, override), "TWILIO_WEBHOOK_URL");
  assert.equal(
    urls.describeWebhookUrl("https://example.supabase.co/functions/v1/sms-inbound?x=1", null),
    "https://example.supabase.co/functions/v1/sms-inbound",
  );
});

test("the edge signer matches the curl script", async () => {
  const token = "12345";
  const url = "https://example.supabase.co/functions/v1/twilio-inbound";
  const params = { To: "+18005551212", From: "+15555550100", Body: "Hello" };
  const fromScript = signTwilioWebhook(token, url, params);
  const fromEdge = await urls.twilioSignature(token, url, params);
  assert.equal(fromEdge, fromScript);
  assert.equal(await urls.twilioSignatureMatches(token, url, params, fromScript), true);
  assert.equal(await urls.twilioSignatureMatches(token, url, params, "nope"), false);

  const candidates = urls.webhookCandidates({
    requestUrl: "http://internal/twilio-inbound",
    forwardedHost: "example.supabase.co",
    host: "internal",
    override: null,
    supabaseUrl: "https://example.supabase.co",
  });
  const hits = [];
  for (const candidate of candidates) {
    if (await urls.twilioSignatureMatches(token, candidate, params, fromScript)) hits.push(candidate);
  }
  assert.deepEqual(hits, [url]);
});
