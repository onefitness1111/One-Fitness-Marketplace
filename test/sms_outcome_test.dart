import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/sms_outcome.dart";

void main() {
  test("sent, pending and not-chosen show nothing", () {
    expect(smsOutcomeNotice(null), isNull);
    expect(smsOutcomeNotice("pending"), isNull);
    expect(smsOutcomeNotice("sent 1"), isNull);
    expect(smsOutcomeNotice("skipped: sms not chosen"), isNull);
  });

  test("each skip reason reads plainly", () {
    expect(smsOutcomeNotice("skipped: replied STOP"), "Not texted: they replied STOP");
    expect(smsOutcomeNotice("skipped: no mobile number"), "Not texted: no mobile number on file");
    expect(smsOutcomeNotice("skipped: texting is off for this coach"), "Not texted: texting is off for your account");
    expect(smsOutcomeNotice("held: invites off"), contains("haven't agreed"));
    expect(smsOutcomeNotice("skipped: something new"), "Not texted: something new");
  });
}
