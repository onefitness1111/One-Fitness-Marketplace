import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/notification_triggers.dart";

/// The welcome note is the owner-editable Welcome template in the database.
/// The app only picks the first name and asks the server to send it.
void main() {
  group("first name from a combined name", () {
    test("takes the first word", () {
      expect(firstNameFrom("Chris McCarthy"), "Chris");
      expect(firstNameFrom("Dana"), "Dana");
    });

    test("survives the messy ones", () {
      expect(firstNameFrom("  Marcus   Lee  "), "Marcus");
      expect(firstNameFrom(""), "");
      expect(firstNameFrom("   "), "");
    });
  });
}
