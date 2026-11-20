import "../../data/models/food_log.dart";
import "../../data/models/nutrition_plan.dart";

/// Meal slots, in the same order the client logs them.
const foodLogSlots = <(String, String)>[
  ("breakfast", "Breakfast"),
  ("lunch", "Lunch"),
  ("dinner", "Dinner"),
  ("snacks", "Snacks"),
  ("smoothies", "Smoothies"),
];

/// A logged line whose numbers were estimated.
///
/// A plate photo is stored with an id starting with "snap-" and a unit of
/// "plate". Quick add stores an id starting with "est-" when a macro was
/// left blank and then filled in. Typing all three macros uses "log-".
bool foodLogEntryIsEstimated(FoodLogItem item) =>
    item.id.startsWith("snap-") || item.id.startsWith("est-") || item.unit.trim().toLowerCase() == "plate";

class FoodLogTargets {
  const FoodLogTargets({required this.calories, this.protein, this.carbs, this.fats});

  final int calories;
  final double? protein;
  final double? carbs;
  final double? fats;
}

class FoodLogSlotLines {
  const FoodLogSlotLines({required this.key, required this.label, required this.lines});

  final String key;
  final String label;
  final List<FoodLogItem> lines;
}

/// One day's log against the client's targets. Read-only: nothing here writes.
class FoodLogDaySummary {
  const FoodLogDaySummary({
    required this.date,
    required this.logged,
    required this.targets,
    required this.slots,
  });

  final String date;
  final MacroSnapshot logged;
  final FoodLogTargets? targets;
  final List<FoodLogSlotLines> slots;

  bool get isEmpty => slots.every((slot) => slot.lines.isEmpty);
}

/// Training-day targets when they have a calorie goal, otherwise rest day.
/// That matches the budget the client's own food log opens on.
FoodLogTargets? foodLogTargetsFor(NutritionPlan? plan) {
  if (plan == null) return null;
  final training = _from(plan.trainingTargets);
  if (training != null) return training;
  return _from(plan.restTargets);
}

FoodLogDaySummary foodLogDaySummary({
  required FoodLog log,
  required String date,
  NutritionPlan? nutrition,
}) {
  final slots = [
    for (final slot in foodLogSlots)
      FoodLogSlotLines(key: slot.$1, label: slot.$2, lines: log.lines(date, slot.$1)),
  ];
  return FoodLogDaySummary(
    date: date,
    logged: log.totalsFor(date),
    targets: foodLogTargetsFor(nutrition),
    slots: slots,
  );
}

FoodLogTargets? _from(MacroTargets targets) {
  final calories = int.tryParse((targets.calories ?? "").trim()) ?? 0;
  if (calories <= 0) return null;
  double? grams(String? pct, double kcalPerGram) {
    final p = double.tryParse((pct ?? "").trim());
    if (p == null || p <= 0) return null;
    return calories * (p / 100) / kcalPerGram;
  }

  return FoodLogTargets(
    calories: calories,
    protein: grams(targets.protein, 4),
    carbs: grams(targets.carbs, 4),
    fats: grams(targets.fats, 9),
  );
}
