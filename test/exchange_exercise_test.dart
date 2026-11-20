import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/programs/exchange_exercise.dart";
import "package:onefitness/data/models/exercise_prescription.dart";
import "package:onefitness/data/models/program_day.dart";

void main() {
  test("exchange replaces one row on that day and keeps the old prescription", () {
    final days = [
      ProgramDay(
        id: "push",
        title: "Push",
        exercises: [
          const ExercisePrescription(id: "a", name: "Bench Press", exerciseId: "bench", group: "Chest", sets: 4, reps: 8, weight: "135", rest: "90s", notes: "Pause at the bottom"),
          const ExercisePrescription(id: "b", name: "Fly", sets: 3, reps: 12),
        ],
      ),
      ProgramDay(
        id: "pull",
        title: "Pull",
        exercises: const [
          ExercisePrescription(id: "c", name: "Bench Press", exerciseId: "bench", sets: 4, reps: 8, weight: "135", rest: "90s", notes: "Pause at the bottom"),
        ],
      ),
    ];

    final next = exchangeExerciseOnDay(
      days: days,
      dayId: "push",
      prescriptionId: "a",
      name: "Incline Press",
      exerciseId: "incline",
      group: "Chest",
    );

    final swapped = next.first.exercises.first;
    expect(swapped.id, "a");
    expect(swapped.name, "Incline Press");
    expect(swapped.exerciseId, "incline");
    expect(swapped.group, "Chest");
    expect(swapped.sets, 4);
    expect(swapped.reps, 8);
    expect(swapped.weight, "135");
    expect(swapped.rest, "90s");
    expect(swapped.notes, "Pause at the bottom");
    expect(next.first.exercises[1].name, "Fly");
    expect(next[1].exercises.single.name, "Bench Press");
    expect(next[1].exercises.single.exerciseId, "bench");
  });
}
