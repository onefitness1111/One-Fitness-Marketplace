import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/live_log/live_log_store.dart";
import "package:onefitness/core/utils/program_utils.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/exercise_prescription.dart";
import "package:onefitness/data/models/workout_log.dart";
import "package:onefitness/features/client/plans/exercise_set_grid.dart";

ClientRecord person(String id, {double lastWeight = 0}) => ClientRecord(
      id: id,
      workoutLogs: lastWeight == 0
          ? const []
          : [
              WorkoutLogEntry(
                id: "log-$id",
                date: "2026-11-01",
                programId: "p",
                programName: "Program",
                dayId: "day",
                dayTitle: "Day",
                exercises: [
                  LoggedExercise(
                    name: "Dumbbell incline bench press",
                    sets: [
                      LoggedSet(setNum: 1, completed: true, completedWeight: lastWeight, completedReps: 10),
                    ],
                  ),
                ],
              ),
            ],
    );

ExercisePrescription bench() => const ExercisePrescription(
      id: "ex-bench",
      exerciseId: "catalog-bench",
      name: "Dumbbell incline bench press",
      sets: 4,
      reps: 10,
    );

ExercisePrescription row() => const ExercisePrescription(
      id: "ex-row",
      exerciseId: "catalog-row",
      name: "Seated row",
      sets: 4,
      reps: 8,
    );

void main() {
  test("20 stays 20, and an older 2 cannot replace it", () {
    final store = LiveLogStore();
    final first = DateTime.utc(2026, 11, 18, 12, 0, 1);
    final second = DateTime.utc(2026, 11, 18, 12, 0, 2);
    store.remember(
      sessionId: "run",
      clientId: "marine",
      exerciseId: "catalog-bench",
      setIndex: 1,
      field: "weight",
      raw: "2",
      at: first,
    );
    store.remember(
      sessionId: "run",
      clientId: "marine",
      exerciseId: "catalog-bench",
      setIndex: 1,
      field: "weight",
      raw: "20",
      at: second,
    );
    store.remember(
      sessionId: "run",
      clientId: "marine",
      exerciseId: "catalog-bench",
      setIndex: 1,
      field: "weight",
      raw: "2",
      at: first,
    );
    expect(
      store.raw(sessionId: "run", clientId: "marine", exerciseId: "catalog-bench", setIndex: 1, field: "weight"),
      "20",
    );
    expect(liveLogWeight("20"), 20);
    expect(liveLogWeight("20.5"), 20.5);
  });

  test("two clients and two exercises do not share a value", () {
    final store = LiveLogStore();
    final at = DateTime.utc(2026, 11, 18);
    store.remember(
      sessionId: "run",
      clientId: "marine",
      exerciseId: "catalog-bench",
      setIndex: 1,
      field: "weight",
      raw: "20",
      at: at,
    );
    store.remember(
      sessionId: "run",
      clientId: "violet",
      exerciseId: "catalog-row",
      setIndex: 1,
      field: "weight",
      raw: "110",
      at: at,
    );
    expect(
      store.raw(sessionId: "run", clientId: "violet", exerciseId: "catalog-row", setIndex: 1, field: "weight"),
      "110",
    );
    expect(
      store.raw(sessionId: "run", clientId: "marine", exerciseId: "catalog-row", setIndex: 1, field: "weight"),
      isNull,
    );
    expect(
      store.raw(sessionId: "run", clientId: "violet", exerciseId: "catalog-bench", setIndex: 1, field: "weight"),
      isNull,
    );
  });

  test("last weight comes from that client's own history", () {
    final marine = person("marine", lastWeight: 20);
    final violet = person("violet", lastWeight: 110);
    expect(getLastSetData(marine, "Dumbbell incline bench press", 1, "day").weight, 20);
    expect(getLastSetData(violet, "Dumbbell incline bench press", 1, "day").weight, 110);
    expect(getLastSetData(marine, "Seated row", 1, "day").weight, 0);
  });

  testWidgets("leaving the grid and coming back restores the full number for that client only", (tester) async {
    final store = LiveLogStore();
    Future<void> pump(String clientId, ExercisePrescription exercise) {
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ExerciseSetGrid(
                exercise: exercise,
                client: person(clientId),
                sessionData: const {},
                onSetChange: (_, _, _, _) {},
                dayId: "day",
                logStore: store,
                sessionId: "run",
                clientId: clientId,
              ),
            ),
          ),
        ),
      );
    }

    await pump("marine", bench());
    await tester.enterText(find.byType(TextField).at(4), "20");
    await tester.pump();
    expect(
      store.raw(sessionId: "run", clientId: "marine", exerciseId: "catalog-bench", setIndex: 1, field: "weight"),
      "20",
    );

    await pump("violet", row());
    expect(tester.widget<TextField>(find.byType(TextField).at(4)).controller!.text, isNot("20"));

    await pump("marine", bench());
    expect(tester.widget<TextField>(find.byType(TextField).at(4)).controller!.text, "20");
  });
}
