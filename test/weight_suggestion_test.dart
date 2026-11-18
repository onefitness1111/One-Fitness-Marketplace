import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/weight_suggestion.dart";
import "package:onefitness/data/models/workout_log.dart";

WorkoutLogEntry session({
  required String id,
  required String when,
  required String exercise,
  required List<LoggedSet> sets,
  String? also,
  List<LoggedSet>? alsoSets,
}) {
  return WorkoutLogEntry(
    id: id,
    date: when.substring(0, 10),
    programId: "prog",
    programName: "Strength",
    dayId: "d1",
    dayTitle: "Day 1",
    loggedAt: when,
    exercises: [
      LoggedExercise(name: exercise, sets: sets),
      if (also != null) LoggedExercise(name: also, sets: alsoSets ?? const []),
    ],
  );
}

LoggedSet done({required int reps, required double weight, int target = 8}) {
  return LoggedSet(
    setNum: 1,
    targetReps: target,
    completedReps: reps,
    completedWeight: weight,
    completed: true,
  );
}

List<LoggedSet> threeSets({
  required int reps,
  required double weight,
  int target = 8,
}) {
  return [
    for (var n = 1; n <= 3; n++)
      LoggedSet(
        setNum: n,
        targetReps: target,
        completedReps: reps,
        completedWeight: weight,
        completed: true,
      ),
  ];
}

void main() {
  test("two sessions in a row at the target suggest one step up", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Bench Press",
        sets: threeSets(reps: 8, weight: 100),
      ),
      session(
        id: "2",
        when: "2026-11-04T10:00:00",
        exercise: "Bench Press",
        sets: threeSets(reps: 8, weight: 100),
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "bench press",
        targetReps: 8,
        targetWeight: 100,
        kind: PlateKind.barbell,
      ),
      105,
    );
  });

  test("a miss on the latest session clears the streak", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Squat",
        sets: threeSets(reps: 5, weight: 185, target: 5),
      ),
      session(
        id: "2",
        when: "2026-11-04T10:00:00",
        exercise: "Squat",
        sets: threeSets(reps: 5, weight: 185, target: 5),
      ),
      session(
        id: "3",
        when: "2026-11-08T10:00:00",
        exercise: "Squat",
        sets: [
          done(reps: 5, weight: 185, target: 5),
          done(reps: 4, weight: 185, target: 5),
          done(reps: 5, weight: 185, target: 5),
        ],
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Squat",
        targetReps: 5,
        targetWeight: 185,
        kind: PlateKind.barbell,
      ),
      isNull,
    );
  });

  test("a miss between two hits means they have not gone up yet", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Row",
        sets: threeSets(reps: 10, weight: 50, target: 10),
      ),
      session(
        id: "2",
        when: "2026-11-03T10:00:00",
        exercise: "Row",
        sets: threeSets(reps: 8, weight: 50, target: 10),
      ),
      session(
        id: "3",
        when: "2026-11-06T10:00:00",
        exercise: "Row",
        sets: threeSets(reps: 10, weight: 50, target: 10),
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Row",
        targetReps: 10,
        targetWeight: 50,
        kind: PlateKind.machine,
      ),
      isNull,
    );
  });

  test("two hits after a miss count again", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Row",
        sets: threeSets(reps: 8, weight: 80, target: 10),
      ),
      session(
        id: "2",
        when: "2026-11-03T10:00:00",
        exercise: "Row",
        sets: threeSets(reps: 10, weight: 80, target: 10),
      ),
      session(
        id: "3",
        when: "2026-11-06T10:00:00",
        exercise: "Row",
        sets: threeSets(reps: 10, weight: 80, target: 10),
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Row",
        targetReps: 10,
        targetWeight: 80,
        kind: PlateKind.machine,
      ),
      85,
    );
  });

  test("one exercise missing does not reset a different exercise", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Bench Press",
        sets: threeSets(reps: 8, weight: 135),
        also: "Curl",
        alsoSets: threeSets(reps: 8, weight: 20, target: 12),
      ),
      session(
        id: "2",
        when: "2026-11-04T10:00:00",
        exercise: "Bench Press",
        sets: threeSets(reps: 8, weight: 135),
        also: "Curl",
        alsoSets: threeSets(reps: 12, weight: 20, target: 12),
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Bench Press",
        targetReps: 8,
        targetWeight: 135,
        kind: PlateKind.barbell,
      ),
      140,
    );
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Curl",
        targetReps: 12,
        targetWeight: 20,
        kind: PlateKind.dumbbell,
      ),
      isNull,
    );
  });

  test("coming in under the target weight is a miss", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Press",
        sets: threeSets(reps: 8, weight: 40),
      ),
      session(
        id: "2",
        when: "2026-11-04T10:00:00",
        exercise: "Press",
        sets: threeSets(reps: 8, weight: 35),
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Press",
        targetReps: 8,
        targetWeight: 40,
        kind: PlateKind.machine,
      ),
      isNull,
    );
  });

  test(
    "a single session is not enough, and the program weight is not changed",
    () {
      const prescribed = "100";
      final logs = [
        session(
          id: "1",
          when: "2026-11-01T10:00:00",
          exercise: "Deadlift",
          sets: threeSets(reps: 5, weight: 100, target: 5),
        ),
      ];
      expect(
        suggestWeightIncrease(
          logs: logs,
          exerciseName: "Deadlift",
          targetReps: 5,
          targetWeight: parseTargetWeight(prescribed),
          kind: PlateKind.barbell,
        ),
        isNull,
      );
      expect(prescribed, "100");
    },
  );

  test("does not suggest a lighter weight than the client just lifted", () {
    final logs = [
      session(
        id: "1",
        when: "2026-11-01T10:00:00",
        exercise: "Squat",
        sets: threeSets(reps: 5, weight: 100, target: 5),
      ),
      session(
        id: "2",
        when: "2026-11-04T10:00:00",
        exercise: "Squat",
        sets: threeSets(reps: 5, weight: 110, target: 5),
      ),
    ];
    expect(
      suggestWeightIncrease(
        logs: logs,
        exerciseName: "Squat",
        targetReps: 5,
        targetWeight: 100,
        kind: PlateKind.barbell,
      ),
      isNull,
    );
  });

  test("rounds to a practical step and never less than one step up", () {
    expect(nextWorkingWeight(100, PlateKind.barbell), 105);
    expect(nextWorkingWeight(135, PlateKind.barbell), 140);
    expect(nextWorkingWeight(185, PlateKind.barbell), 190);
    expect(nextWorkingWeight(200, PlateKind.barbell), 205);
    expect(nextWorkingWeight(45, PlateKind.barbell), 50);
    // 210 * 1.025 is 215.25, so 215 is too small and the next 5 lb is 220.
    expect(nextWorkingWeight(210, PlateKind.barbell), 220);

    expect(nextWorkingWeight(20, PlateKind.dumbbell), 22.5);
    expect(nextWorkingWeight(10, PlateKind.dumbbell), 12.5);
    expect(nextWorkingWeight(22.5, PlateKind.dumbbell), 25);
    expect(nextWorkingWeight(25, PlateKind.dumbbell), 30);
    expect(nextWorkingWeight(30, PlateKind.dumbbell), 35);
    expect(nextWorkingWeight(50, PlateKind.dumbbell), 55);

    expect(nextWorkingWeight(80, PlateKind.machine), 85);
    expect(nextWorkingWeight(40, PlateKind.machine), 45);
    expect(nextWorkingWeight(0, PlateKind.barbell), isNull);
  });

  test("equipment names pick the step", () {
    expect(plateKindFor(["Barbell", "Bench"]), PlateKind.barbell);
    expect(plateKindFor(["Dumbbell"]), PlateKind.dumbbell);
    expect(plateKindFor(["Leg Press Machine"]), PlateKind.machine);
    expect(plateKindFor(["Cable Machine"]), PlateKind.machine);
    expect(plateKindFor(["EZ Bar"]), PlateKind.barbell);
  });
}
