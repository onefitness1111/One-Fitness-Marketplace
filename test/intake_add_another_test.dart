import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/intake_schema.dart";
import "package:onefitness/features/client/intake/form_filler_screen.dart";

/// Adding another copy of an intake form for one client.
///
/// A new filing opens with the previous answers already filled in, so only
/// what changed has to be typed. Saving still archives the previous filing.
void main() {
  const schema = IntakeSchema(
    title: "Personalized Training Intake",
    sections: [
      IntakeSection(
        title: "Goals",
        questions: [IntakeQuestion(id: "goal", label: "Main goal", type: "text")],
      ),
    ],
  );

  final filled = ClientRecord(
    id: "c1",
    intake: {
      "personalTraining": const IntakeRecord(
        answers: {"goal": "Lose fat"},
        completed: true,
        at: "2026-05-14",
        by: "Client",
      ),
    },
  );

  Future<void> pump(WidgetTester tester, {required bool keepPrevious}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: FormFillerScreen(
              assessmentKey: "personalTraining",
              schema: schema,
              onBack: () {},
              profileId: "p1",
              client: filled,
              who: "trainer",
              onSaved: (_) {},
              keepPrevious: keepPrevious,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets("editing opens on what the client already said", (tester) async {
    await pump(tester, keepPrevious: false);
    expect(find.text("Lose fat"), findsOneWidget);
  });

  testWidgets("a new filing starts from the previous answers", (tester) async {
    await pump(tester, keepPrevious: true);
    expect(find.text("Lose fat"), findsOneWidget);
    expect(find.text("Main goal"), findsOneWidget);
  });
}
