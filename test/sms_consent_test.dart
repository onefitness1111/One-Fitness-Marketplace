import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/legal/sms_consent.dart";
import "package:onefitness/data/models/client_info.dart";

/// A2P 10DLC / CTIA express written consent. The carrier campaign was
/// rejected (Twilio error 30909) for not evidencing how users consent, so
/// these guard the two things that caused it: consent defaulting to on, and
/// the disclosure missing required elements.
void main() {
  test("a client is opted OUT unless they actively opt in", () {
    // Default-on is not consent — it is what got the campaign rejected.
    expect(const ClientInfo(id: "c1", name: "Test").smsOptIn, isFalse);
  });

  group("the disclosure carries every element carriers require", () {
    final full = "$kSmsConsentLabel $kSmsConsentDisclosure";

    test("names the sender", () {
      expect(full, contains("ONE Fitness"));
    });

    test("says what the messages are", () {
      expect(full.toLowerCase(), contains("reminders"));
      expect(full.toLowerCase(), contains("booking"));
    });

    test("states message frequency", () {
      expect(full, contains("Message frequency varies"));
    });

    test("states that rates may apply", () {
      expect(full, contains("Message and data rates may apply"));
    });

    test("gives both STOP and HELP keywords", () {
      expect(full, contains("STOP"));
      expect(full, contains("HELP"));
      expect(full, contains("Reply STOP to opt out"));
    });

    test("says consent is not required to buy", () {
      expect(full, contains("Consent is not required to buy"));
    });

    test("points at the terms and privacy policy", () {
      expect(full, contains("Terms of Use"));
      expect(full, contains("Privacy Policy"));
    });
  });

  test("the stored record is the wording agreed to, plus its version", () {
    final record = smsConsentRecord();
    expect(record, contains(kSmsConsentLabel));
    expect(record, contains(kSmsConsentDisclosure));
    expect(record, contains(kSmsConsentVersion),
        reason: "consent must stay attributable to the exact text shown");
  });

  test("turning texts off in the app is a decline, and turning them on clears it", () {
    final off = smsPreferenceClientWrite(optIn: false, now: "2026-11-21T12:00:00Z");
    expect(off["sms_opt_in"], isFalse);
    expect(off["sms_opt_in_at"], isNull);
    expect(off["sms_consent_text"], isNull);
    expect(off["sms_declined_at"], "2026-11-21T12:00:00Z");
    expect(smsPreferenceProfileWrite(optIn: false), {
      "sms_consent_at": null,
      "sms_consent_text": null,
    });

    final on = smsPreferenceClientWrite(optIn: true, now: "2026-11-21T12:05:00Z");
    expect(on["sms_opt_in"], isTrue);
    expect(on["sms_declined_at"], isNull);
    expect(on["sms_consent_text"], smsConsentRecord());
    expect(smsPreferenceProfileWrite(optIn: true), isNull);
  });
}
