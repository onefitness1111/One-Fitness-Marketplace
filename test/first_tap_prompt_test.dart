import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/session/login_prompts.dart";
import "package:onefitness/core/widgets/tap_highlight.dart";

void main() {
  tearDown(LoginPrompts.reset);

  testWidgets("a scroll does not ask, and the first tap asks for notifications then the waiver", (tester) async {
    final events = <String>[];
    final release = Completer<void>();
    LoginPrompts.arm();
    LoginPrompts.attach(
      () => runLoginPromptSequence(
        requestNotifications: () async {
          events.add("notifications");
          await release.future;
        },
        waiverNeeded: () => true,
        showWaiver: () async {
          events.add("waiver");
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < 40; i++) SizedBox(height: 48, child: Text("row $i")),
                  ],
                ),
              ),
              TextButton(onPressed: gateLoginTap(() => events.add("open")), child: const Text("Open")),
              TapHighlight(onTap: () => events.add("book"), child: const Text("Book")),
            ],
          ),
        ),
      ),
    );

    await tester.fling(find.byType(ListView), const Offset(0, -400), 1200);
    await tester.pumpAndSettle();
    expect(events, isEmpty, reason: "scrolling the dashboard is not a tap");

    await tester.tap(find.text("Open"));
    await tester.pump();
    expect(events, ["notifications"]);

    release.complete();
    await tester.pumpAndSettle();
    expect(events, ["notifications", "waiver"]);

    await tester.tap(find.text("Book"));
    await tester.pumpAndSettle();
    expect(events, ["notifications", "waiver", "book"]);
  });

  testWidgets("the waiver is skipped when it is not still needed", (tester) async {
    final events = <String>[];
    LoginPrompts.arm();
    LoginPrompts.attach(
      () => runLoginPromptSequence(
        requestNotifications: () async => events.add("notifications"),
        waiverNeeded: () => false,
        showWaiver: () async => events.add("waiver"),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextButton(onPressed: gateLoginTap(() => events.add("open")), child: const Text("Open")),
        ),
      ),
    );

    await tester.tap(find.text("Open"));
    await tester.pumpAndSettle();
    expect(events, ["notifications"]);

    await tester.tap(find.text("Open"));
    await tester.pumpAndSettle();
    expect(events, ["notifications", "open"]);
  });
}
