import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/nutrition/food_log_view.dart";
import "package:onefitness/data/models/food_log.dart";
import "package:onefitness/data/models/nutrition_plan.dart";

void main() {
  const oats = FoodLogItem(id: "oats", name: "Oats", qty: 1, unit: "cup", calories: 300, protein: 10, carbs: 50, fats: 6);
  const plate = FoodLogItem(id: "snap-9", name: "Chicken plate", qty: 1, unit: "plate", calories: 540, protein: 40, carbs: 30, fats: 22);

  FoodLog log() => FoodLog(days: {
        "2026-05-30": {
          "breakfast": [oats],
          "dinner": [plate],
        },
        "2026-05-31": {
          "lunch": [oats],
        },
      });

  test("a day lists its own meals and marks a snapped plate as estimated", () {
    final day = foodLogDaySummary(log: log(), date: "2026-05-30");
    expect(day.isEmpty, isFalse);
    expect(day.logged.calories, 840);
    expect(day.logged.protein, 50);
    expect(foodLogEntryIsEstimated(plate), isTrue);
    expect(foodLogEntryIsEstimated(oats), isFalse);
    expect(day.slots.firstWhere((s) => s.key == "lunch").lines, isEmpty);
    expect(day.slots.firstWhere((s) => s.key == "dinner").lines.single.name, "Chicken plate");
  });

  test("another day is not mixed in", () {
    final day = foodLogDaySummary(log: log(), date: "2026-05-31");
    expect(day.logged.calories, 300);
    expect(day.slots.firstWhere((s) => s.key == "dinner").lines, isEmpty);
  });

  test("an empty day has no lines", () {
    final day = foodLogDaySummary(log: log(), date: "2026-06-01");
    expect(day.isEmpty, isTrue);
    expect(day.logged.calories, 0);
  });

  test("totals are compared with the training-day targets", () {
    const plan = NutritionPlan(
      trainingTargets: MacroTargets(calories: "2000", protein: "30", carbs: "40", fats: "30"),
    );
    final targets = foodLogTargetsFor(plan)!;
    expect(targets.calories, 2000);
    expect(targets.protein, 150);
    expect(targets.carbs, 200);
    expect(targets.fats, closeTo(66.67, 0.01));
  });
}
