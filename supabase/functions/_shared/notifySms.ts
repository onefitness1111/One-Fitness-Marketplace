// Texts a client only when they opted in and have not replied STOP or
// turned texts off. During quiet hours (9pm-8am Pacific) the text waits in
// sms_outbox until 8:00am instead of going out. See autoSms.ts.
import { sendAutoSms } from "./autoSms.ts";

// deno-lint-ignore no-explicit-any
export async function smsClientIfOptedIn(admin: any, profileId: string, text: string, kind = "notice"): Promise<boolean> {
  const outcome = await sendAutoSms(admin, { profileId, text, kind });
  return outcome === "sent" || outcome === "deferred" || outcome === "already queued";
}
