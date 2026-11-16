#!/usr/bin/env node
// Sign a sample Twilio webhook so you can check the inbound text handler
// after it is deployed.
//
// The gym number was answering every text with "403 Forbidden" because the
// signature check looked at the wrong web address. This builds the same
// signature Twilio sends, then prints a curl command. A working deploy
// answers 200, not 403.
//
// Usage (the token stays on your machine — do not paste it into chat):
//   TWILIO_AUTH_TOKEN="your auth token" node scripts/sign-twilio-webhook.mjs \
//     --url "https://rivhgutksyddeckieknc.supabase.co/functions/v1/twilio-inbound"
//
// Check the signer itself, with no token and no network:
//   node scripts/sign-twilio-webhook.mjs --self-test

import crypto from "node:crypto";

// Same rule as twilioSignature() in supabase/functions/_shared/twilioWebhookUrl.ts:
// HMAC-SHA1 over the full URL, then each form field name and value in
// alphabetical order, keyed by the Auth Token, base64.
export function signTwilioWebhook(token, url, params) {
  const payload = Object.keys(params).sort().reduce((acc, key) => acc + key + params[key], url);
  return crypto.createHmac("sha1", token).update(payload, "utf8").digest("base64");
}

function parseArgs(argv) {
  const out = { selfTest: false, body: "Hello", from: "+15555550100", to: "+18182237001" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--self-test") out.selfTest = true;
    else if (arg === "--token") out.token = argv[++i];
    else if (arg === "--url") out.url = argv[++i];
    else if (arg === "--body") out.body = argv[++i];
    else if (arg === "--from") out.from = argv[++i];
    else if (arg === "--to") out.to = argv[++i];
    else if (arg === "--help") out.help = true;
  }
  return out;
}

function selfTest() {
  const token = "12345";
  const url = "https://example.com/functions/v1/twilio-inbound";
  const params = {
    Body: "Hello",
    From: "+15555550100",
    To: "+18005551212",
  };
  const signature = signTwilioWebhook(token, url, params);
  const again = signTwilioWebhook(token, url, { To: params.To, Body: params.Body, From: params.From });
  if (signature !== again) {
    console.error("self-test failed: field order changed the signature");
    process.exit(1);
  }
  if (signature !== "ody5hYc/P9nloS5AbsHka4/rqVM=") {
    console.error(`self-test failed: unexpected signature ${signature}`);
    process.exit(1);
  }
  console.log("self-test ok");
}

const invokedDirectly = process.argv[1] && import.meta.url === new URL(process.argv[1], "file:").href;
if (invokedDirectly) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("See the comment at the top of scripts/sign-twilio-webhook.mjs");
    process.exit(0);
  }
  if (args.selfTest) {
    selfTest();
    process.exit(0);
  }

  const token = args.token || process.env.TWILIO_AUTH_TOKEN;
  const url = args.url;
  if (!token || !url) {
    console.error("Need TWILIO_AUTH_TOKEN (or --token) and --url. Run with --self-test to check the signer offline.");
    process.exit(1);
  }

  const params = { Body: args.body, From: args.from, To: args.to };
  const signature = signTwilioWebhook(token, url, params);
  const data = new URLSearchParams(params).toString();

  console.log("Signed sample. After the fix is deployed, the reply should be HTTP 200. HTTP 403 means the signature still does not match.");
  console.log("This sample uses a fake From number, so it should not text a real client. To see the coach auto-reply, text the gym number from your phone.");
  console.log("");
  console.log(`curl -sS -D - -o /tmp/twilio-inbound-reply.xml \\
  -X POST ${JSON.stringify(url)} \\
  -H ${JSON.stringify(`X-Twilio-Signature: ${signature}`)} \\
  -H "Content-Type: application/x-www-form-urlencoded" \\
  --data ${JSON.stringify(data)}`);
}
