// Twilio delivery reports (StatusCallback) for texts we send.
//
// Code only. Twilio calls this only after the secret
// TWILIO_STATUS_CALLBACK_URL is set to this function's public URL
// (https://<project>.supabase.co/functions/v1/twilio-status). That needs
// Coach Chris's okay. Nothing in the Twilio console changes.
//
// Deploy WITHOUT jwt verification (Twilio sends no JWT):
//   supabase functions deploy twilio-status --no-verify-jwt
// Every request must carry a valid X-Twilio-Signature.
//
// What it records, by message SID in sms_log: queued/sent/delivered/
// undelivered/failed and the error code. No phone number or text is stored.
// Error 21610 (STOP at Twilio) marks the number opted out. Unreachable /
// landline errors mark it undeliverable so we stop trying.

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { phoneTail, TWILIO_OPTED_OUT, TWILIO_UNDELIVERABLE } from "../_shared/phoneRules.mjs";
import { markPhone } from "../_shared/sendSms.ts";
import { twilioSignatureMatches, webhookCandidates } from "../_shared/twilioWebhookUrl.ts";

const KNOWN = new Set(["accepted", "queued", "sending", "sent", "delivered", "undelivered", "failed", "read", "canceled"]);

serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  try {
    const raw = await req.text();
    const params: Record<string, string> = {};
    for (const [k, v] of new URLSearchParams(raw)) params[k] = v;

    const override = Deno.env.get("TWILIO_STATUS_CALLBACK_URL") ?? null;
    const candidates = webhookCandidates({
      requestUrl: req.url,
      forwardedHost: req.headers.get("x-forwarded-host"),
      host: req.headers.get("host"),
      override,
      supabaseUrl: Deno.env.get("SUPABASE_URL") ?? null,
    });
    const signature = req.headers.get("x-twilio-signature") ?? "";
    const token = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
    let ok = false;
    for (const url of candidates) {
      if (await twilioSignatureMatches(token, url, params, signature)) {
        ok = true;
        break;
      }
    }
    if (!ok) {
      console.warn(`twilio-status: signature matched none of ${candidates.length} candidates`);
      return new Response("Forbidden", { status: 403 });
    }

    const sid = String(params["MessageSid"] ?? params["SmsSid"] ?? "").trim();
    const status = String(params["MessageStatus"] ?? params["SmsStatus"] ?? "").trim().toLowerCase();
    const code = Number(params["ErrorCode"] ?? "") || null;
    const to = String(params["To"] ?? "");
    if (!sid || !KNOWN.has(status)) return new Response(null, { status: 204 });

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { error } = await admin.from("sms_log").upsert({
      sid,
      status,
      error_code: code,
      updated_at: new Date().toISOString(),
    }, { onConflict: "sid" });
    if (error) console.warn(`twilio-status: log failed: ${error.message}`);

    if (code && to) {
      if (TWILIO_OPTED_OUT.has(code)) await markPhone(to, "stop");
      else if (TWILIO_UNDELIVERABLE.has(code)) await markPhone(to, "undeliverable");
    }
    console.log(`twilio-status: ${status}${code ? ` (${code})` : ""} for …${phoneTail(to)}`);
    return new Response(null, { status: 204 });
  } catch (e) {
    console.error("twilio-status failed:", e instanceof Error ? e.message : String(e));
    return new Response(null, { status: 204 });
  }
});
