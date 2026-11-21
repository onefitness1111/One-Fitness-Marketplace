import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/data/providers/trainer_providers.dart";
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
      "Merit Badges",
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

    await tester.tap(
      find.descendant(of: tabs, matching: find.text("Progress")),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Overview"), findsOneWidget);
    expect(find.text("AWARD A BADGE"), findsNothing);
    expect(find.text("ALL MERIT BADGES — REFERENCE"), findsNothing);

    await tester.tap(find.text("Body"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("MEASUREMENTS"), findsWidgets);
    expect(find.text("AWARD A BADGE"), findsNothing);

    await tester.tap(find.text("Photos"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("PROGRESS PHOTOS"), findsWidgets);
    expect(find.text("AWARD A BADGE"), findsNothing);

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

    await tester.tap(find.descendant(of: tabs, matching: find.text("More")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text("Merit Badges"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("AWARD A BADGE"), findsOneWidget);
    expect(find.textContaining("ACTIVE ("), findsOneWidget);
    expect(find.text("ALL MERIT BADGES — REFERENCE"), findsOneWidget);
    expect(find.text("OWNER OVERRIDE — ASSIGN ANY BADGE"), findsNothing);
  });

  testWidgets("the owner override stays on the merit badges screen", (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> openAs(String auth) async {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(auth),
          overrides: [
            trainerAuthProvider.overrideWith(() => _FixedAuth(auth)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TrainerView(clientId: "demo-jordan")),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text("More"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text("Merit Badges"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await openAs("owner");
    expect(find.text("OWNER OVERRIDE — ASSIGN ANY BADGE"), findsOneWidget);
    expect(find.text("AWARD A BADGE"), findsOneWidget);

    await openAs("coach-1");
    expect(find.text("OWNER OVERRIDE — ASSIGN ANY BADGE"), findsNothing);
    expect(find.text("AWARD A BADGE"), findsOneWidget);
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

class _FixedAuth extends TrainerAuthNotifier {
  _FixedAuth(this.value);

  final String value;

  @override
  String? build() => value;
}
