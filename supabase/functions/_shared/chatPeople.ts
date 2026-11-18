// Names and consent for a text. Coaches and the owner never contribute a
// legal name. The owner is always "ONE Fitness Marketplace".

export const BUSINESS_NAME = "ONE Fitness Marketplace";

const CONSENT_TEXT =
  "Text me booking confirmations, reminders and waitlist offers from ONE Fitness. " +
  "Message frequency varies. Message and data rates may apply. " +
  "Reply STOP to unsubscribe or HELP for help. See our Terms of Use and Privacy Policy. " +
  "(opted in by replying START)";

export function toE164(raw: string): string | null {
  const d = String(raw || "").replace(/\D/g, "");
  if (String(raw || "").trim().startsWith("+") && d.length >= 8) return `+${d}`;
  if (d.length === 10) return `+1${d}`;
  if (d.length === 11 && d.startsWith("1")) return `+${d}`;
  return null;
}

// deno-lint-ignore no-explicit-any
type Admin = any;

export async function displayName(admin: Admin, id: string): Promise<string> {
  const { data } = await admin.from("profiles").select("role, name").eq("id", id).maybeSingle();
  if (!data) return "Someone";
  if (data.role === "owner") return BUSINESS_NAME;
  if (data.role === "coach") {
    const { data: pub } = await admin.rpc("coach_public_name", { p_id: id });
    const name = String(pub || "").trim();
    return name || "Coach";
  }
  const client = String(data.name || "").trim();
  return client || "Client";
}

export async function loadParty(admin: Admin, id: string) {
  const { data: profile } = await admin
    .from("profiles")
    .select("id, role, phone, sms_opted_out, sms_consent_at")
    .eq("id", id)
    .maybeSingle();
  if (!profile) return null;
  const { data: client } = await admin.from("clients").select("sms_opt_in").eq("profile_id", id).maybeSingle();
  const name = await displayName(admin, id);
  return {
    id: profile.id as string,
    role: String(profile.role || ""),
    displayName: name,
    coachName: String(profile.role) === "coach" ? name : "",
    phone: String(profile.phone || "").trim(),
    optedOut: profile.sms_opted_out === true,
    hasConsent: profile.sms_consent_at != null || client?.sms_opt_in === true,
  };
}

export async function loadCoaches(admin: Admin) {
  const { data: profiles } = await admin.from("profiles").select("id").eq("role", "coach").is("deleted_at", null);
  const coaches = [];
  for (const row of profiles ?? []) {
    const party = await loadParty(admin, row.id as string);
    if (party) coaches.push(party);
  }
  return coaches;
}

export async function markOptOut(admin: Admin, profileId: string): Promise<void> {
  await admin.from("profiles").update({
    sms_opted_out: true,
    sms_consent_at: null,
    sms_consent_text: null,
  }).eq("id", profileId);
  await admin.from("clients").update({
    sms_opt_in: false,
    sms_opt_in_at: null,
    sms_consent_text: null,
  }).eq("profile_id", profileId);
}

export async function markOptIn(admin: Admin, profileId: string): Promise<void> {
  const now = new Date().toISOString();
  await admin.from("profiles").update({
    sms_opted_out: false,
    sms_consent_at: now,
    sms_consent_text: CONSENT_TEXT,
  }).eq("id", profileId);
  await admin.from("clients").update({
    sms_opt_in: true,
    sms_opt_in_at: now,
    sms_consent_text: CONSENT_TEXT,
  }).eq("profile_id", profileId);
}

/** Twilio line type. null when the lookup itself failed. Landlines are not texted. */
export async function lineType(sid: string, token: string, e164: string): Promise<string | null> {
  try {
    const res = await fetch(
      `https://lookups.twilio.com/v2/PhoneNumbers/${encodeURIComponent(e164)}?Fields=line_type_intelligence`,
      { headers: { Authorization: `Basic ${btoa(`${sid}:${token}`)}` } },
    );
    if (!res.ok) return null;
    const data = await res.json();
    return (data?.line_type_intelligence?.type as string | undefined) ?? null;
  } catch {
    return null;
  }
}
