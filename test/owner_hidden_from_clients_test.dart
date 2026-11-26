import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/privacy/owner_hidden.dart";
import "package:onefitness/core/supabase/supabase_service.dart";

void main() {
  group("OWNER HIDDEN: clients never see an owner profile", () {
    test("isOwnerProfileId matches owner ids only", () {
      expect(isOwnerProfileId("owner-1", const ["owner-1"]), isTrue);
      expect(isOwnerProfileId("coach-chris", const ["owner-1"]), isFalse);
      expect(isOwnerProfileId("", const [""]), isFalse);
    });

    test("the coach list built for clients never includes an owner row", () {
      final directory = [
        {"id": "owner-1", "role": "owner", "name": "Owner"},
        {"id": "coach-chris", "role": "coach", "name": "Coach Chris"},
      ];
      final rows = [
        {"profile_id": "owner-1"},
        {"profile_id": "coach-chris"},
      ];
      final trainers = SupabaseService.trainersFromParts(directory, rows);
      expect(trainers.map((t) => t.id), ["coach-chris"]);
    });

    test("both client profile openers refuse an owner id", () {
      for (final f in const [
        "lib/features/client/booking/coach_profile_screen.dart",
        "lib/core/widgets/coach_profile_card.dart",
      ]) {
        expect(File(f).readAsStringSync().contains("isOwnerProfileId("), isTrue, reason: f);
      }
    });
  });
}
