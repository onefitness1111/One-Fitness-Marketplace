import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/data/mock/mock_data.dart";
import "package:onefitness/data/models/workout_log.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/features/client/plans/workout_tab.dart";

void main() {
  setUp(() => AppColors.apply(AppPalette.dark));

  Future<void> pumpTab(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkoutTab())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets("lists every program day and checks the current round", (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handle = tester.ensureSemantics();
    await pumpTab(tester, container);

    expect(find.text("1 of 2 done"), findsOneWidget);
    expect(find.text("New round"), findsNothing);
    expect(find.text("Monday"), findsNothing);
    expect(find.text("Day 1"), findsOneWidget);
    expect(find.text("Push Day"), findsOneWidget);
    expect(find.text("Day 2"), findsOneWidget);
    expect(find.text("Pull Day"), findsOneWidget);
    expect(find.text("Barbell Bench Press"), findsNothing);
    expect(find.text("Deadlift"), findsNothing);
    expect(find.bySemanticsLabel("Day 1, completed"), findsOneWidget);
    expect(find.bySemanticsLabel("Day 2"), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel("Day 1, completed")).value,
      "Push Day",
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel("Day 2")).value,
      "Pull Day",
    );

    final check = tester.widget<Icon>(find.byIcon(Icons.check));
    expect(check.color, AppColors.txt);
    expect(check.color, isNot(AppColors.statusGreen));
    expect(check.color, isNot(AppColors.calendarDone));

    await tester.tap(find.text("Day 2"));
    await tester.pumpAndSettle();
    expect(find.text("Deadlift"), findsOneWidget);
    expect(find.text("4 sets · 6 reps · 185"), findsOneWidget);
    expect(find.text("3 sets · 8 reps"), findsOneWidget);
    expect(find.text("Start workout"), findsOneWidget);
    expect(find.text("Barbell Bench Press"), findsNothing);

    await tester.tap(find.text("Day 1"));
    await tester.pumpAndSettle();
    expect(find.text("Barbell Bench Press"), findsOneWidget);
    expect(find.text("4 sets · 8 reps · 135"), findsOneWidget);
    expect(find.text("Deadlift"), findsNothing);
    expect(find.text("Start workout"), findsOneWidget);

    await tester.tap(find.text("Day 1"));
    await tester.pumpAndSettle();
    expect(find.text("Barbell Bench Press"), findsNothing);
    expect(find.text("Start workout"), findsNothing);
    handle.dispose();
  });

  testWidgets("finishing the round clears the checks", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(clientRecordProvider.notifier)
        .update(
          (r) => r.copyWith(
            workoutLogs: [
              ...r.workoutLogs,
              const WorkoutLogEntry(
                id: "wl-pull",
                date: "2099-01-02",
                loggedAt: "2099-01-02T09:00:00",
                programId: "prog-alex-ppl",
                programName: "Push / Pull",
                dayId: "day-pull",
                dayTitle: "Pull Day",
              ),
            ],
          ),
        );
    await pumpTab(tester, container);

    expect(find.text("New round"), findsOneWidget);
    expect(find.textContaining("done"), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.text("Day 1"), findsOneWidget);
    expect(find.text("Day 2"), findsOneWidget);
  });

  testWidgets("no logs is a new round and no program keeps the empty line", (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpTab(tester, container);

    container
        .read(clientRecordProvider.notifier)
        .update((r) => r.copyWith(workoutLogs: const []));
    await tester.pumpAndSettle();
    expect(find.text("New round"), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.text("Day 1"), findsOneWidget);

    container
        .read(clientRecordProvider.notifier)
        .update((r) => r.copyWith(savedPrograms: const []));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "No active workout program yet. Your coach will assign one to your profile.",
      ),
      findsOneWidget,
    );
    expect(find.text("Day 1"), findsNothing);
    expect(find.text("New round"), findsNothing);

    container
        .read(clientRecordProvider.notifier)
        .update(
          (r) => r.copyWith(
            savedPrograms: [
              MockData.savedPrograms.first.copyWith(status: "archived"),
            ],
          ),
        );
    await tester.pumpAndSettle();
    expect(
      find.text(
        "No active workout program yet. Your coach will assign one to your profile.",
      ),
      findsOneWidget,
    );
  });
}
