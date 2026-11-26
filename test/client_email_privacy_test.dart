import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/privacy/client_email_privacy.dart";

void main() {
  group("C10: client emails are owner-only", () {
    test("coach never gets an email line", () {
      expect(clientEmailForViewer("aiden@example.com", viewerIsOwner: false), isNull);
      expect(clientEmailForViewer("aiden@example.com", viewerIsOwner: true), "aiden@example.com");
      expect(clientEmailForViewer("  ", viewerIsOwner: true), isNull);
      expect(canSeeClientEmail(viewerIsOwner: false), isFalse);
    });

    test("coach searches by name only; owner can also search by email", () {
      bool m(String q, bool owner) =>
          clientMatchesSearch(name: "Aiden Park", email: "ap.lifts@example.com", query: q, viewerIsOwner: owner);
      expect(m("aiden", false), isTrue);
      expect(m("lifts", false), isFalse);
      expect(m("example.com", false), isFalse);
      expect(m("lifts", true), isTrue);
      expect(m("", false), isTrue);
    });

    test("staff and client pickers do not read raw client emails for search or display", () {
      const files = [
        "lib/features/trainer/clients/roster_bar.dart",
        "lib/features/trainer/chat/coach_chat_screen.dart",
        "lib/features/trainer/schedule/client_search_picker.dart",
        "lib/features/client/squad/squad_member_search_screen.dart",
      ];
      final rawSearch = RegExp(r'\(c\.email \?\? ""\)\.toLowerCase\(\)\.contains');
      final rawShow = RegExp(r'Text\(\s*c\.email');
      for (final f in files) {
        final src = File(f).readAsStringSync();
        expect(rawSearch.hasMatch(src), isFalse, reason: "$f searches raw email");
        expect(rawShow.hasMatch(src), isFalse, reason: "$f shows raw email");
      }
    });
  });
}
