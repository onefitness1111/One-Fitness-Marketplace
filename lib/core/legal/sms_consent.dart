/// The SMS opt-in disclosure, in one place so the signup screen, the
/// Notification Preferences screen and the record stored against the client
/// can never drift apart.
///
/// The wording is what CTIA and the carriers require at the point of
/// consent for an A2P 10DLC campaign, and what Twilio's reviewers look for
/// when they check a Call-to-Action (our first submission was rejected with
/// error 30909 for not showing it):
///
///   * who is texting                — "ONE Fitness"
///   * what the messages are         — bookings, reminders, waitlist offers
///   * how often                     — "Message frequency varies"
///   * cost                          — "Message and data rates may apply"
///   * how to stop, and get help     — STOP / HELP
///   * purchase is not conditioned   — consent is not required to buy
///   * where the terms live          — Terms of Use and Privacy Policy
///
/// Consent must also be an affirmative act: this box starts unticked, and
/// `clients.sms_opt_in` defaults to false. A pre-ticked box is not consent.
library;

/// Bump when the wording changes materially — the text agreed to is stored
/// per client alongside the timestamp, so old consents stay attributable to
/// what they actually said.
const String kSmsConsentVersion = "2026-11-21";

/// The single line shown next to the checkbox.
const String kSmsConsentLabel =
    "Text me booking confirmations, reminders and waitlist offers from ONE Fitness.";

/// The required disclosures, shown directly under the label.
const String kSmsConsentDisclosure =
    "Message frequency varies. Message and data rates may apply. "
    "Reply STOP to opt out or HELP for help. "
    "Consent is not required to buy. "
    "See our Terms of Use and Privacy Policy.";

/// What gets stored against the client as the record of what they agreed
/// to, so there is evidence to show a carrier if consent is ever queried.
String smsConsentRecord() => "$kSmsConsentLabel $kSmsConsentDisclosure (v$kSmsConsentVersion)";

/// The client row written when they use the Text messages switch.
/// Turning it off sets [sms_declined_at]. That is a no: no texts, and no
/// invite. Turning it on clears that. "Not now" does not call this — a
/// snooze leaves sms_declined_at unset, which is not a no.
Map<String, Object?> smsPreferenceClientWrite({
  required bool optIn,
  required String now,
}) =>
    {
      "sms_opt_in": optIn,
      "sms_opt_in_at": optIn ? now : null,
      "sms_consent_text": optIn ? smsConsentRecord() : null,
      "sms_declined_at": optIn ? null : now,
    };

/// Turning texts off also clears the profile consent timestamp, so a stale
/// yes cannot keep texts going. Turning them on does not write the profile
/// here; the screen that showed the disclosure does that.
Map<String, Object?>? smsPreferenceProfileWrite({required bool optIn}) {
  if (optIn) return null;
  return {
    "sms_consent_at": null,
    "sms_consent_text": null,
  };
}
