import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/owner_thread_name.dart";

void main() {
  group("Client view of a direct thread with the owner", () {
    test("the name is exactly ONE Fitness Market", () {
      expect(kOwnerThreadNameForClients, "ONE Fitness Market");
    });

    test("the owner's real name in a sender prefix becomes ONE Fitness Market", () {
      expect(
        ownerThreadTextForClient("Chris McCarthy: See you at 6", ownerNames: const ["Chris McCarthy"]),
        "ONE Fitness Market: See you at 6",
      );
    });

    test("business labels become ONE Fitness Market too, longest match first", () {
      expect(ownerThreadTextForClient("ONE Fitness Marketplace: Hi"), "ONE Fitness Market: Hi");
      expect(ownerThreadTextForClient("ONE Fitness: Hi"), "ONE Fitness Market: Hi");
      expect(ownerThreadTextForClient("ONE Fitness Market: Hi"), "ONE Fitness Market: Hi");
    });

    test("other text and coach messages are left alone", () {
      expect(ownerThreadTextForClient("Coach Chris: On my way", ownerNames: const ["Chris McCarthy"]), "Coach Chris: On my way");
      expect(ownerThreadTextForClient("thanks!", ownerNames: const ["Chris McCarthy"]), "thanks!");
      expect(ownerThreadTextForClient("Hi", ownerNames: const [""]), "Hi");
    });

    test("the client chat names the owner thread ONE Fitness Market and never uses owner.name", () {
      final src = File("lib/features/client/chat/chat_screen.dart").readAsStringSync();
      expect(src, contains("name: kOwnerThreadNameForClients,"));
      expect(src, contains("coachName: kOwnerThreadNameForClients,"));
      expect(src.contains("name: owner.name"), isFalse);
      expect(src.contains("coachName: owner.name"), isFalse);
      // Bubbles, the list preview, and the report excerpt use the client view.
      expect("_clientText(".allMatches(src).length, greaterThanOrEqualTo(4));
    });

    test("owner and coach screens are unchanged", () {
      for (final f in const [
        "lib/features/trainer/chat/coach_chat_screen.dart",
        "lib/core/widgets/owner_chat_list.dart",
      ]) {
        expect(File(f).readAsStringSync().contains("kOwnerThreadNameForClients"), isFalse, reason: f);
      }
    });
  });
}
