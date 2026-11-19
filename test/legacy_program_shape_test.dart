import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/supabase/supabase_service.dart";
import "package:onefitness/core/utils/plate_math.dart";
import "package:onefitness/core/utils/workout_logging.dart";

/// Shapes confirmed against stored records: sets and reps sometimes text,
/// a day with no kind, a meal slot that is one object, flat macro targets,
/// and a workout log from before swaps existed.
void main() {
  test("an older workout program still opens for logging", () {
    final record = SupabaseService.parseStoredRecord("client-1", {
      "savedPrograms": [
        {
          "id": "prog-1",
          "type": "workout",
          "name": "Lower",
          "status": "active",
          "source": "coach",
          "createdBy": "Coach Chris",
          "createdAt": "2026-01-01",
          "modifiedAt": "2026-01-02",
          "programDays": [
            {
              "id": "day-1",
              "title": "Legs",
              "exercises": [
                {
                  "id": "row-1",
                  "name": "Leg Press",
                  "exerciseId": "ex-leg-press",
                  "sets": "3",
                  "reps": "10",
                  "weight": 135,
                  "clientFlag": null,
                  "time": "",
                  "distance": "",
                  "rest": "",
                  "notes": "",
                  "group": "",
                  "laterality": "bilateral",
                },
                {
                  "id": "row-2",
                  "name": "Curl",
                  "sets": "3",
                  "reps": "8-12",
                  "weight": "",
                  "clientFlag": null,
                },
                {
                  "id": "row-3",
                  "name": "Hold",
                  "sets": "",
                  "reps": "",
                  "weight": "",
                  "clientFlag": null,
                },
              ],
            },
          ],
        },
      ],
      "workoutLogs": [
        {
          "id": "log-1",
          "date": "2026-02-01",
          "programId": "prog-1",
          "programName": "Lower",
          "dayId": "day-1",
          "dayTitle": "Legs",
          "loggedAt": "2026-02-01T18:00:00Z",
          "loggedBy": "client",
          "exercises": [
            {
              "name": "Leg Press",
              "sets": [
                {"setNum": 1, "targetReps": 10, "completedReps": 10, "completedWeight": 180, "completed": true},
              ],
            },
          ],
        },
      ],
    });

    final day = record.savedPrograms.single.programDays.single;
    expect(day.suggested, isFalse);
    expect(day.exercises[0].sets, 3);
    expect(day.exercises[0].reps, 10);
    expect(day.exercises[0].weight, "135");
    expect(platesPerSide(135).perSide, [45]);
    expect(day.exercises[1].reps, 8);
    expect(day.exercises[2].sets, 3);
    expect(day.exercises[2].reps, 0);

    final last = lastTimeFor(record.workoutLogs, "Leg Press", 1);
    expect(last?.reps, 10);
    expect(last?.weight, 180);
    expect(record.workoutLogs.single.swaps, isEmpty);
    expect(record.foodLog.days, isEmpty);
  });

  test("days saved only on the old program list still become a program", () {
    final record = SupabaseService.parseStoredRecord("client-2", {
      "program": [
        {
          "id": "old-day",
          "title": "Push",
          "exercises": [
            {"id": "bench", "name": "Bench", "sets": 4, "reps": 6, "weight": "95"},
          ],
        },
      ],
      "logs": [
        {
          "id": "old-log",
          "date": "2025-12-01",
          "exercises": [
            {
              "name": "Bench",
              "sets": [
                {"setNum": 1, "completed": true, "completedReps": 6, "completedWeight": 95},
              ],
            },
          ],
        },
      ],
    });

    expect(record.savedPrograms.single.name, "Your program");
    expect(record.savedPrograms.single.programDays.single.exercises.single.name, "Bench");
    expect(record.workoutLogs.single.date, "2025-12-01");
    expect(lastTimeFor(record.workoutLogs, "Bench", 1)?.weight, 95);
  });

  test("an older nutrition plan with flat targets and one meal object still loads", () {
    final record = SupabaseService.parseStoredRecord("client-3", {
      "nutrition": {
        "targets": {"calories": 2200, "protein": 160, "carbs": 200, "fats": 70},
        "mealBudgets": {"breakfast": "500", "lunch": "700"},
        "breakfast": {
          "id": "oats",
          "name": "Oats",
          "calories": 400,
          "protein": 20,
          "carbs": 60,
          "fats": 10,
          "ingredients": [
            {"item": "Oats", "qty": "80", "unit": "g"},
          ],
        },
        "lunch": [],
        "dinner": [],
        "snacks": [],
        "smoothies": [],
      },
      "savedNutritionPrograms": [
        {
          "id": "nut-1",
          "type": "nutrition",
          "name": "Cut",
          "status": "active",
          "source": "coach",
          "targets": {"calories": 2000, "protein": 150, "carbs": 180, "fats": 60},
          "mealBudgets": {"breakfast": "400"},
        },
      ],
    });

    final plan = record.nutrition!;
    expect(plan.trainingTargets.calories, "2200");
    expect(plan.breakfast.single.name, "Oats");
    expect(plan.breakfast.single.ingredients.single.qty, 80);
    expect(plan.mealBudgets.training["lunch"], "700");
    expect(record.savedNutritionPrograms.single.trainingTargets.calories, "2000");
    expect(record.foodLog.days, isEmpty);
  });
}
