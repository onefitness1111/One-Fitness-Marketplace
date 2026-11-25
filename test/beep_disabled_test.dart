import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/feature_flags.dart";
import "package:onefitness/core/notifications/push_service.dart";
import "package:onefitness/features/client/beep/beep_bar.dart";
import "package:onefitness/features/trainer/beep/coach_beep_alerts.dart";

/// The 1.1.6 pin: Beep Your Coach is off, but every file that implements it
/// stays in the tree so it can be switched back on later.
void main() {
  test("the compile-time switch is off", () {
    expect(kBeepYourCoachEnabled, isFalse);
  });

  test("beep push payloads are ignored, and other pushes are not", () {
    expect(PushService.shouldHandlePush({"type": "beep"}), isFalse);
    expect(PushService.shouldHandlePush({"type": "chat"}), isTrue);
    expect(PushService.shouldHandlePush({"type": "sms_opt_in"}), isTrue);
    expect(PushService.shouldHandlePush(<String, dynamic>{}), isTrue);
  });

  test("every user-visible surface is gated on the switch", () {
    const paths = [
      "lib/features/client/plans/workout_tab.dart",
      "lib/features/shared/session_logger_view.dart",
      "lib/features/client/beep/beep_bar.dart",
      "lib/features/client/beep/client_live_session_layer.dart",
      "lib/features/trainer/beep/coach_beep_alerts.dart",
      "lib/features/trainer/dashboard/trainer_home_screen.dart",
      "lib/features/trainer/settings/customize_platform_screen.dart",
      "lib/core/notifications/push_service.dart",
    ];
    for (final path in paths) {
      expect(
        File(path).readAsStringSync().contains("kBeepYourCoachEnabled"),
        isTrue,
        reason: "$path should check kBeepYourCoachEnabled",
      );
    }
  });

  test("the feature's files, providers, models and migrations are kept", () {
    const kept = [
      "lib/features/client/beep/beep_bar.dart",
      "lib/features/client/beep/client_live_session_layer.dart",
      "lib/features/trainer/beep/coach_beep_alerts.dart",
      "lib/data/providers/beep_providers.dart",
      "lib/core/notifications/beep_sounds.dart",
      "lib/data/models/live_session.dart",
      "supabase/migrations/20261118160000_live_days_history_notify.sql",
    ];
    for (final path in kept) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  testWidgets("BeepBar renders nothing while the feature is off", (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: BeepBar(exerciseNames: ["Bench Press"], focusIndex: 0),
          ),
        ),
      ),
    );
    expect(find.text("Beep Your Coach"), findsNothing);
    expect(find.text("Help"), findsNothing);
    expect(find.text("Spot"), findsNothing);
    expect(find.text("Done"), findsNothing);
    expect(tester.getSize(find.byType(BeepBar)).height, 0);
  });

  testWidgets(
    "CoachBeepAlerts renders only its child while the feature is off",
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: CoachBeepAlerts(
              trainerId: "coach-1",
              child: Text("session body"),
            ),
          ),
        ),
      );
      expect(find.text("session body"), findsOneWidget);
      expect(find.text("needs help"), findsNothing);
      expect(find.text("needs a spot"), findsNothing);
    },
  );
}
