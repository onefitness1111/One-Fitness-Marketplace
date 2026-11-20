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
    final gap = tester.getTopLeft(find.byKey(const Key("quick-action-Message"))).dy -
        tester.getBottomLeft(tabs).dy;
    expect(gap, greaterThanOrEqualTo(8));
    expect(gap, lessThanOrEqualTo(12));

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

  testWidgets("quick actions scroll away with the page", (tester) async {
    tester.view.physicalSize = const Size(390, 700);
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

    final action = find.byKey(const Key("quick-action-Message"));
    final tabs = find.byKey(const Key("client-tabs"));
    final tabsTop = tester.getTopLeft(tabs).dy;
    final name = find.text("Jordan Casey");
    expect(tester.getTopLeft(action).dy, greaterThan(tabsTop));
    final nameBefore = tester.getTopLeft(name).dy;
    expect(nameBefore, greaterThan(tester.getTopLeft(action).dy));

    await tester.drag(name, const Offset(0, -160));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.getTopLeft(tabs).dy, tabsTop);
    expect(tester.getTopLeft(name).dy, lessThan(nameBefore));
    final nestedTop = tester.getTopLeft(find.byType(NestedScrollView)).dy;
    final stillBuilt = action.evaluate();
    if (stillBuilt.isNotEmpty) {
      final box = tester.renderObject<RenderBox>(action);
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      expect(bottom, lessThanOrEqualTo(nestedTop + 1));
    }
  });
}
