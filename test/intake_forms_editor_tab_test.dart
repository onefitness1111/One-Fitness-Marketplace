import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/memberships/manage_intake_forms_screen.dart";

void main() {
  Future<ProviderContainer> pump(WidgetTester tester, String who) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(trainerAuthProvider.notifier).signIn(who);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ManageIntakeFormsScreen())),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets("U1: the owner gets the Intake Forms editor", (tester) async {
    await pump(tester, "owner");
    expect(find.text("New form"), findsOneWidget);
    expect(find.textContaining("Only the owner"), findsNothing);
  });

  testWidgets("U1: a coach cannot edit intake forms", (tester) async {
    await pump(tester, "coach-1");
    expect(find.text("New form"), findsNothing);
    expect(find.textContaining("Only the owner can change intake forms."), findsOneWidget);
  });

  test("U1: Customize Platform has an Intake Forms tab that opens the editor", () {
    final src = File("lib/features/trainer/settings/customize_platform_screen.dart").readAsStringSync();
    expect(src, contains('("intake", "Intake Forms")'));
    expect(src, contains('if (_tab == "intake")'));
    expect(src, contains("ManageIntakeFormsScreen()"));
    // Customize Platform itself only opens for the owner.
    final shell = File("lib/features/trainer/shell/trainer_shell.dart").readAsStringSync();
    expect(shell, contains('"platformSettings" when isOwner => const CustomizePlatformScreen()'));
  });

  test("U1: the editor never shows the word AI", () {
    final src = File("lib/features/trainer/memberships/manage_intake_forms_screen.dart").readAsStringSync();
    final visible = src.split("\n").where((l) => !l.trimLeft().startsWith("//"));
    expect(visible.any((l) => RegExp(r'"[^"]*\bAI\b').hasMatch(l)), isFalse);
  });
}
