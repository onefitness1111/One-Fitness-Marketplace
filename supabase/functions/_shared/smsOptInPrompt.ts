// Who may be asked, in the app, to opt in to texts.
//
// A client qualifies when sms_opt_in is not true (false or missing) and
// they have not opted out. Coach assignment is not part of this decision.
// Keep this in step with lib/core/legal/sms_opt_in_prompt.dart.

export const SMS_OPT_IN_PUSH_TITLE = "Tap to get texts from your coach";
export const SMS_OPT_IN_PUSH_BODY =
  "Open the app to agree. No text is sent until you say yes.";

export type SmsPromptProfile = {
  id: string;
  smsOptedOut: boolean;
};

export type SmsPromptClient = {
  profileId: string;
  smsOptIn: boolean | null;
};

export function smsOptInPromptRecipients(input: {
  profiles: SmsPromptProfile[];
  clients: SmsPromptClient[];
}): string[] {
  const optIn = new Map(input.clients.map((row) => [row.profileId, row.smsOptIn]));
  const ids: string[] = [];
  for (const profile of input.profiles) {
    if (!profile.id) continue;
    if (profile.smsOptedOut) continue;
    const flag = optIn.has(profile.id) ? optIn.get(profile.id) : null;
    if (flag === true) continue;
    ids.push(profile.id);
  }
  return ids;
}

export function smsOptInPushData(): Record<string, string> {
  return { kind: "sms-opt-in", screen: "dashboard" };
}
