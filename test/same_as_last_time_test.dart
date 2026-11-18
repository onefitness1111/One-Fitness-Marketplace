import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/workout_logging.dart";
import "package:onefitness/data/models/workout_log.dart";

WorkoutLogEntry log({
  required String id,
  required String date,
  required String exercise,
  required List<LoggedSet> sets,
  String? loggedAt,
}) =>
    WorkoutLogEntry(
      id: id,
      date: date,
      programId: "p",
      programName: "Program",
      dayId: "day",
      dayTitle: "Day",
      loggedAt: loggedAt,
      exercises: [LoggedExercise(name: exercise, sets: sets)],
    );

void main() {
  test("same as last time uses this client's newest session, set by set", () {
    final logs = [
      log(
        id: "old",
        date: "2026-10-01",
        exercise: "Back squat",
        sets: const [LoggedSet(setNum: 1, completed: true, completedReps: 5, completedWeight: 135)],
      ),
      log(
        id: "new",
        date: "2026-11-01",
        loggedAt: "2026-11-01T18:00:00Z",
        exercise: "Back squat",
        sets: const [
          LoggedSet(setNum: 1, completed: true, completedReps: 8, completedWeight: 185),
          LoggedSet(setNum: 2, completed: true, completedReps: 6, completedWeight: 185),
        ],
      ),
      log(
        id: "other-day-same-date",
        date: "2026-11-01",
        loggedAt: "2026-11-01T12:00:00Z",
        exercise: "Back squat",
        sets: const [LoggedSet(setNum: 1, completed: true, completedReps: 3, completedWeight: 95)],
      ),
      log(
        id: "other-lift",
        date: "2026-11-02",
        exercise: "Bench press",
        sets: const [LoggedSet(setNum: 1, completed: true, completedReps: 10, completedWeight: 100)],
      ),
    ];

    final first = lastTimeFor(logs, "back squat", 1);
    final second = lastTimeFor(logs, "Back squat", 2);
    expect(first?.reps, 8);
    expect(first?.weight, 185);
    expect(second?.reps, 6);
    expect(lastTimeFor(logs, "Back squat", 3), isNull);
    expect(lastTimeFor(logs, "Bench press", 1)?.weight, 100);
  });

  test("a set that was never finished is skipped", () {
    final logs = [
      log(
        id: "blank",
        date: "2026-11-01",
        exercise: "Row",
        sets: const [LoggedSet(setNum: 1, completed: false)],
      ),
    ];
    expect(lastTimeFor(logs, "Row", 1), isNull);
  });
}
