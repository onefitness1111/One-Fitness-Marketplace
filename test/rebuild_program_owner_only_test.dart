import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/intake_resubmit.dart";

final _ai = RegExp(r"\bAI\b|\bA\.I\.|artificial intelligence|Claude|GPT", caseSensitive: false);

void main() {
  group("O3: Rebuild program after a new intake", () {
    test("owner wording names the rebuild and never mentions AI", () {
      expect(rebuildProgramLabel("training"), "Rebuild training program");
      expect(rebuildProgramLabel("nutrition"), "Rebuild nutrition program");
      final hint = rebuildProgramHint("Nov 25, 6:24 PM");
      expect(hint, contains("newest intake"));
      expect(hint, contains("Nov 25, 6:24 PM"));
      for (final s in [rebuildProgramLabel("training"), rebuildProgramLabel("nutrition"), hint]) {
        expect(_ai.hasMatch(s), isFalse, reason: s);
      }
    });

    test("coaches and clients only ever see the neutral line", () {
      expect(programRefreshLabel("training", forOwner: false), "Program update pending");
      expect(_ai.hasMatch(programRefreshLabel("nutrition", forOwner: false)), isFalse);
    });

    test("the button sits behind the owner check, and the rebuild refuses non-owners", () {
      final profile = File("lib/features/trainer/clients/profile_tab.dart").readAsStringSync();
      final at = profile.indexOf("rebuildProgramLabel(kind)");
      expect(at, greaterThan(0));
      final guard = profile.lastIndexOf("if (isOwner && widget.onRequestProgram != null)", at);
      expect(guard, greaterThan(0));
      expect(at - guard, lessThan(800));

      final plans = File("lib/features/trainer/clients/plans_tab.dart").readAsStringSync();
      final fn = plans.indexOf("Future<void> _draftFromRefresh(String kind) async {");
      expect(plans.substring(fn, fn + 200), contains('if (ref.read(trainerAuthProvider) != "owner") return;'));
    });

    test("the server functions still only let the owner generate", () {
      for (final f in const [
        "supabase/functions/generate-ai-workout-program/index.ts",
        "supabase/functions/generate-ai-nutrition-program/index.ts",
      ]) {
        expect(File(f).readAsStringSync(), contains('callerProfile?.role !== "owner"'), reason: f);
      }
    });
  });
}
