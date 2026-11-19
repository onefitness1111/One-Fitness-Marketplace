import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/supabase/contact_reads.dart";

void main() {
  test("a phone comes back from profile_contact_for, not the profiles table", () {
    expect(
      phoneFromContactRows([
        {"id": "me", "email": "a@b.co", "phone": " 555-0100 "},
      ]),
      "555-0100",
    );
    expect(phoneFromContactRows([{"phone": "  "}]), isNull);
    expect(phoneFromContactRows([]), isNull);
    expect(phoneFromContactRows(null), isNull);
  });

  test("chat intro and SMS consent read only the signed-in prefs row", () {
    expect(chatIntroSeenFromPrefs({"chat_intro_seen_at": "2026-11-19"}), isTrue);
    expect(chatIntroSeenFromPrefs({"chat_intro_seen_at": null}), isFalse);
    expect(chatIntroSeenFromPrefs(null), isFalse);

    expect(smsConsentFromPrefs({"sms_opted_out": true, "sms_consent_at": "2026-11-19"}), isFalse);
    expect(smsConsentFromPrefs({"sms_opted_out": false, "sms_consent_at": "2026-11-19"}), isTrue);
    expect(smsConsentFromPrefs({"sms_opted_out": false, "sms_consent_at": null}), isNull);
    expect(smsConsentFromPrefs(null), isNull);
  });
}
