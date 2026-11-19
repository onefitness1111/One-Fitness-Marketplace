// Unchanged copy of the live helper. Texts a client only when they opted in.
import { sendSms } from "./sendSms.ts";

// deno-lint-ignore no-explicit-any
export async function smsClientIfOptedIn(admin: any, profileId: string, text: string): Promise<boolean> {
  const { data: prefs } = await admin.from("clients").select("sms_opt_in").eq("profile_id", profileId).maybeSingle();
  if (prefs?.sms_opt_in !== true) return false;
  const { data: profile } = await admin.from("profiles").select("phone").eq("id", profileId).maybeSingle();
  const phone = String(profile?.phone ?? "").trim();
  if (!phone) return false;
  await sendSms(phone, `ONE Fitness: ${text}`);
  return true;
}
