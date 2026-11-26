import "package:flutter_test/flutter_test.dart";

import "package:onefitness/features/trainer/clients/profile_tab.dart";

/// C1: the freeze form must not promise to move the billing date. A freeze
/// skips the charges inside it, and billing resumes on the normal date.
void main() {
  test("the freeze form says billing dates are skipped, not shifted", () {
    final text = freezeFormExplainer("Jordan");
    expect(text.toLowerCase(), isNot(contains("shifts")));
    expect(text, contains("billing date inside the freeze is skipped"));
    expect(text, contains("billing date stays the same"));
    expect(text, contains("first day Jordan can book again"));
  });
}
