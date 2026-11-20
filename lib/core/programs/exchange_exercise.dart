import "../../data/models/exercise_prescription.dart";
import "../../data/models/program_day.dart";

/// Swap the library exercise in one row, on one day.
///
/// The row keeps its id and its sets, reps, weight, rest, and notes, so the
/// editor opens already filled with what the old exercise used. Other days,
/// including a row for the same movement, are left alone.
List<ProgramDay> exchangeExerciseOnDay({
  required List<ProgramDay> days,
  required String dayId,
  required String prescriptionId,
  required String name,
  required String exerciseId,
  String? group,
}) {
  return [
    for (final day in days)
      if (day.id != dayId)
        day
      else
        day.copyWith(
          exercises: [
            for (final exercise in day.exercises)
              if (exercise.id != prescriptionId)
                exercise
              else
                ExercisePrescription(
                  id: exercise.id,
                  name: name,
                  exerciseId: exerciseId,
                  group: group,
                  sets: exercise.sets,
                  reps: exercise.reps,
                  weight: exercise.weight,
                  time: exercise.time,
                  distance: exercise.distance,
                  rest: exercise.rest,
                  notes: exercise.notes,
                  laterality: exercise.laterality,
                  supersetId: exercise.supersetId,
                  clientNoteText: exercise.clientNoteText,
                  clientNoteAt: exercise.clientNoteAt,
                ),
          ],
        ),
  ];
}
