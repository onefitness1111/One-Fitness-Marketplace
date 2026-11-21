import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:onefitness/core/session/login_prompts.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/data/models/exercise_def.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/exercises/exercises_screen.dart";
import "package:onefitness/features/trainer/shell/trainer_shell.dart";
import "package:onefitness/features/trainer/shell/trainer_shell_state.dart";

/// A coach (not the owner) opened Exercises from the menu. The phone is a
/// typical iPhone size: this is the layout that went black in release.
const _phone = Size(390, 844);

void main() {
  setUp(() {
    AppColors.apply(AppPalette.dark);
    SharedPreferences.setMockInitialValues({});
    LoginPrompts.reset();
    ExercisesScreen.debugThrowInBuild = false;
  });

  tearDown(() {
    LoginPrompts.reset();
    ExercisesScreen.debugThrowInBuild = false;
  });

  testWidgets("coach exercises page shows the header, search, and list", (
    tester,
  ) async {
    final catalog = _realisticCatalog(280);
    await _pumpCoachExercises(tester, catalog);

    _expectVisibleHeader(tester, "EXERCISES (280)");
    _expectVisibleSearch(tester);
    expect(find.text("Barbell Bench Press 0"), findsOneWidget);
    expect(find.text("Kettlebell Swing 279"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("an empty catalog still shows the header and search", (
    tester,
  ) async {
    await _pumpCoachExercises(tester, const []);

    _expectVisibleHeader(tester, "EXERCISES (0)");
    _expectVisibleSearch(tester);
    expect(find.text("No exercises match that search."), findsOneWidget);
    final hint = tester.getRect(find.text("No exercises match that search."));
    expect(hint.width, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets("a build failure shows a message instead of a blank page", (
    tester,
  ) async {
    ExercisesScreen.debugThrowInBuild = true;
    await _pumpCoachExercises(tester, _realisticCatalog(4));

    expect(find.text("EXERCISES (4)"), findsNothing);
    final message = find.text(
      "Exercises couldn't be shown. Go back and open them again.",
    );
    expect(message, findsOneWidget);
    expect(tester.getRect(message).width, greaterThan(40));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpCoachExercises(
  WidgetTester tester,
  List<ExerciseDef> catalog,
) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        trainerAuthProvider.overrideWith(() => _CoachAuth()),
        trainerModeProvider.overrideWith(() => _ExercisesMode()),
        exerciseCatalogProvider.overrideWith(() => _FixedCatalog(catalog)),
      ],
      child: const MaterialApp(home: TrainerShell()),
    ),
  );
  // The shell fades the page in. One frame is not enough to paint it.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectVisibleHeader(WidgetTester tester, String label) {
  final header = find.text(label);
  expect(header, findsOneWidget);
  final rect = tester.getRect(header);
  expect(rect.width, greaterThan(40), reason: "$label has no width");
  expect(rect.height, greaterThan(8), reason: "$label has no height");
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(_phone.width));
  expect(rect.top, greaterThan(40), reason: "$label is under the app bar");
}

void _expectVisibleSearch(WidgetTester tester) {
  final search = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == "Search name, muscle, movement, equipment…",
  );
  expect(search, findsOneWidget);
  final rect = tester.getRect(search);
  expect(rect.width, greaterThan(100));
  expect(rect.right, lessThanOrEqualTo(_phone.width));
}

/// Names, muscles, and movement patterns are plain strings. One row carries
/// a long equipment list, the shape of the live catalog (about 280 rows,
/// equipment JSON up to a few hundred characters).
List<ExerciseDef> _realisticCatalog(int count) {
  const muscles = ["Back", "Quads", "Chest", "Core", "Shoulders"];
  const patterns = ["horizontal-pull", "squat", "olympic", "hinge", "push"];
  return [
    for (var i = 0; i < count; i++)
      ExerciseDef(
        id: "ex-$i",
        name: i == 0
            ? "Barbell Bench Press 0"
            : i == count - 1
            ? "Kettlebell Swing ${count - 1}"
            : "Exercise $i",
        movementPattern: patterns[i % patterns.length],
        primaryMuscle: muscles[i % muscles.length],
        equipment: [
          "Barbell",
          if (i == 12)
            // ~400 characters, under the longest equipmentIds JSON in production.
            "Dumbbells, Bench, Cable Machine, Kettlebell, Pull-Up Bar, "
                "Resistance Band, Landmine, Trap Bar, Swiss Ball, "
                "Ab Wheel, Dip Bars, Squat Rack, Leg Press, Rowing Machine",
        ],
      ),
  ];
}

class _CoachAuth extends TrainerAuthNotifier {
  @override
  String? build() => "demo-marcus";
}

class _ExercisesMode extends TrainerModeNotifier {
  @override
  String build() => "exercises";
}

class _FixedCatalog extends ExerciseCatalogNotifier {
  _FixedCatalog(this.items);
  final List<ExerciseDef> items;

  @override
  List<ExerciseDef> build() => items;
}
