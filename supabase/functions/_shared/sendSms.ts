// The one Twilio sender every Edge Function uses.
//
// Before a text goes out:
// - the number must be a real, textable number (phoneRules.mjs), so the
//   made-up test numbers on file are skipped instead of failing at Twilio;
// - the database is asked whether anyone on that number replied STOP or was
//   reported unreachable (sms_phone_status). STOP is final, on every path.
//
// After Twilio answers:
// - error 21610 (they replied STOP to Twilio) marks the number opted out in
//   our database, so it matches what Twilio already enforces;
// - "not a mobile / not reachable" errors mark the number undeliverable;
// - the message SID is logged in sms_log (no phone number, no text) so the
//   twilio-status endpoint can record delivered / failed later.
//
// Delivery reports are opt-in: they are requested only when the secret
// TWILIO_STATUS_CALLBACK_URL is set (Coach Chris has to okay that first).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { phoneTail, textableNumber, TWILIO_OPTED_OUT, TWILIO_UNDELIVERABLE } from "./phoneRules.mjs";

export type SmsResult = {
  ok: boolean;
  sid?: string;
  errorCode?: number;
  /** Why nothing was sent: "invalid number", "opted out", "undeliverable", "not configured", "twilio error". */
  skipped?: string;
};

// deno-lint-ignore no-explicit-any
let cachedAdmin: any = null;
// deno-lint-ignore no-explicit-any
function serviceClient(): any {
  if (cachedAdmin) return cachedAdmin;
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  cachedAdmin = createClient(url, key);
  return cachedAdmin;
}

async function phoneStatus(e164: string): Promise<{ optedOut: boolean; undeliverable: boolean }> {
  const admin = serviceClient();
  if (!admin) return { optedOut: false, undeliverable: false };
  try {
    const { data, error } = await admin.rpc("sms_phone_status", { raw_phone: e164 });
    if (error) {
      console.warn(`sendSms: phone status lookup failed: ${error.message}`);
      return { optedOut: false, undeliverable: false };
    }
    const row = Array.isArray(data) ? data[0] : data;
    return { optedOut: row?.opted_out === true, undeliverable: row?.undeliverable === true };
  } catch (e) {
    console.warn("sendSms: phone status lookup failed:", e instanceof Error ? e.message : String(e));
    return { optedOut: false, undeliverable: false };
  }
}

/** Records STOP (21610) or unreachable numbers on every profile with that number. */
export async function markPhone(e164: string, kind: "stop" | "undeliverable"): Promise<void> {
  const admin = serviceClient();
  if (!admin) return;
  const { error } = await admin.rpc("sms_mark_phone", { raw_phone: e164, p_kind: kind });
  if (error) console.warn(`sendSms: could not mark …${phoneTail(e164)} ${kind}: ${error.message}`);
  else console.log(`sendSms: marked …${phoneTail(e164)} ${kind}`);
}

async function logSid(sid: string, kind: string): Promise<void> {
  const admin = serviceClient();
  if (!admin || !sid) return;
  const { error } = await admin.from("sms_log").insert({ sid, kind, status: "queued" });
  if (error) console.warn(`sendSms: sms_log insert failed: ${error.message}`);
}

async function logFailure(kind: string, code: number | undefined): Promise<void> {
  const admin = serviceClient();
  if (!admin) return;
  await admin.from("sms_log").insert({
    sid: `failed:${crypto.randomUUID()}`,
    kind,
    status: "failed",
    error_code: code ?? null,
  });
}

export async function sendSmsDetailed(to: string, body: string, opts: { kind?: string } = {}): Promise<SmsResult> {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const token = Deno.env.get("TWILIO_AUTH_TOKEN");
  const from = Deno.env.get("TWILIO_FROM_NUMBER");
  const kind = opts.kind ?? "sms";
  if (!sid || !token || !from || !to) return { ok: false, skipped: "not configured" };

  const e164 = textableNumber(to);
  if (!e164) {
    console.log(`sendSms: skipped …${phoneTail(to)} (not a textable number)`);
    return { ok: false, skipped: "invalid number" };
  }
  const status = await phoneStatus(e164);
  if (status.optedOut) {
    console.log(`sendSms: skipped …${phoneTail(e164)} (replied STOP)`);
    return { ok: false, skipped: "opted out" };
  }
  if (status.undeliverable) {
    console.log(`sendSms: skipped …${phoneTail(e164)} (number can't get texts)`);
    return { ok: false, skipped: "undeliverable" };
  }

  const params = new URLSearchParams({ To: e164, From: from, Body: body });
  const callback = (Deno.env.get("TWILIO_STATUS_CALLBACK_URL") ?? "").trim();
  if (callback.startsWith("https://")) params.set("StatusCallback", callback);

  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params.toString(),
  });
  const text = await res.text();
  // deno-lint-ignore no-explicit-any
  let data: any = null;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }
  if (!res.ok) {
    const code = typeof data?.code === "number" ? data.code : undefined;
    console.error(`sendSms failed (${res.status}) code ${code ?? "?"} for …${phoneTail(e164)}: ${data?.message ?? ""}`);
    if (code && TWILIO_OPTED_OUT.has(code)) await markPhone(e164, "stop");
    else if (code && TWILIO_UNDELIVERABLE.has(code)) await markPhone(e164, "undeliverable");
    await logFailure(kind, code);
    return { ok: false, errorCode: code, skipped: "twilio error" };
  }
  const messageSid = String(data?.sid ?? "");
  await logSid(messageSid, kind);
  return { ok: true, sid: messageSid };
}

/** True when Twilio accepted the text. False when it was skipped or refused. */
export async function sendSms(to: string, body: string): Promise<boolean> {
  return (await sendSmsDetailed(to, body)).ok;
}
