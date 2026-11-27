// Texts a client only when they opted in and have not replied STOP.
import { sendSms } from "./sendSms.ts";
import { SMS_PREFIX } from "./businessName.mjs";

// deno-lint-ignore no-explicit-any
export async function smsClientIfOptedIn(admin: any, profileId: string, text: string): Promise<boolean> {
  const { data: prefs } = await admin.from("clients").select("sms_opt_in").eq("profile_id", profileId).maybeSingle();
  if (prefs?.sms_opt_in !== true) return false;
  const { data: profile } = await admin.from("profiles").select("phone, sms_opted_out").eq("id", profileId).maybeSingle();
  // STOP is final even if sms_opt_in was somehow left on.
  if (profile?.sms_opted_out === true) return false;
  const phone = String(profile?.phone ?? "").trim();
  if (!phone) return false;
  await sendSms(phone, `${SMS_PREFIX}${text}`);
  return true;
}
