import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/features/trainer/clients/trainer_view.dart";

void main() {
  testWidgets("top tabs are Profile, Plans, Logged, Progress, and More", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: TrainerView(clientId: "demo-jordan")),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final tabs = find.byKey(const Key("client-tabs"));
    for (final label in ["Profile", "Plans", "Logged", "Progress", "More"]) {
      expect(
        find.descendant(of: tabs, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: tabs, matching: find.text("Visits")),
      findsNothing,
    );
    expect(
      find.descendant(of: tabs, matching: find.text("Photos")),
      findsNothing,
    );
    expect(find.text("Message"), findsOneWidget);
    expect(find.text("Book"), findsOneWidget);
    expect(find.text("Log"), findsOneWidget);
    expect(find.text("Note"), findsOneWidget);
    expect(find.text("RECENT"), findsNothing);
    expect(tester.getSize(find.byKey(const Key("quick-action-Message"))), const Size(32, 32));

    await tester.tap(find.descendant(of: tabs, matching: find.text("More")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final more = find.byKey(const Key("client-more"));
    for (final label in [
      "Visits",
      "Assessments",
      "Documents",
      "Habits",
      "Notes",
      "Squad",
      "Points",
    ]) {
      expect(
        find.descendant(of: more, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: more, matching: find.text("Photos")),
      findsNothing,
    );
    expect(
      find.descendant(of: more, matching: find.text("Badges")),
      findsNothing,
    );

    await tester.tap(
      find.descendant(of: tabs, matching: find.text("Progress")),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("PROGRESS PHOTOS"), findsOneWidget);
    expect(find.text("MEASUREMENTS"), findsOneWidget);
    expect(find.textContaining("MERIT BADGES"), findsWidgets);

    await tester.tap(find.descendant(of: tabs, matching: find.text("More")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key("client-more")),
        matching: find.text("Assessments"),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key("client-more")), findsNothing);
  });
}
