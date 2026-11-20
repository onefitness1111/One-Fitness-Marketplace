import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/chat/broadcast_screen.dart";

void main() {
  testWidgets("a broadcast requires a group name before review", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(trainerAuthProvider.notifier).signIn("demo-marcus");

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: BroadcastScreen())),
    ));
    await tester.pump();

    expect(find.text("Group name"), findsOneWidget);
    expect(find.text("Review"), findsOneWidget);
    expect(find.text("Send via — pick any"), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), "  Morning crew  ");
    await tester.enterText(fields.at(1), "See you at 6");
    await tester.pump();

    await tester.ensureVisible(find.text("Review"));
    await tester.tap(find.text("Review"));
    await tester.pump();

    expect(find.text("Group name: Morning crew"), findsOneWidget);
    expect(find.text("Ready to send"), findsOneWidget);
  });
}
