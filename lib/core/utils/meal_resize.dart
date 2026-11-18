import "../../data/models/meal_def.dart";
import "../../data/models/nutrition_plan.dart";
import "nutrition_helpers.dart";

/// Calorie and macro caps for one meal slot.
///
/// Gram caps come from the day's macro percents applied to this slot's
/// calories: protein and carbs are 4 kcal per gram, fat is 9.
class SlotBudget {
  const SlotBudget({this.calories, this.protein, this.carbs, this.fats});

  final int? calories;
  final double? protein;
  final double? carbs;
  final double? fats;

  bool get constrains =>
      (calories != null && calories! > 0) ||
      (protein != null && protein! > 0) ||
      (carbs != null && carbs! > 0) ||
      (fats != null && fats! > 0);

  static SlotBudget forSlot({
    required int? slotCalories,
    String? proteinPct,
    String? carbsPct,
    String? fatsPct,
  }) {
    double? grams(String? pct, double kcalPerGram) {
      final p = double.tryParse((pct ?? "").trim());
      if (p == null || p <= 0 || slotCalories == null || slotCalories <= 0) return null;
      return slotCalories * (p / 100) / kcalPerGram;
    }

    return SlotBudget(
      calories: slotCalories != null && slotCalories > 0 ? slotCalories : null,
      protein: grams(proteinPct, 4),
      carbs: grams(carbsPct, 4),
      fats: grams(fatsPct, 9),
    );
  }
}

/// A meal's portions after one proportional scale and practical rounding.
class ResizedPortions {
  const ResizedPortions({required this.scale, required this.ingredients, required this.macros});

  final double scale;
  final List<Ingredient> ingredients;
  final MacroSnapshot macros;
}

/// Step size for a kitchen unit. Countable foods land on whole numbers.
double practicalStep(String? unit) {
  final u = (unit ?? "").trim().toLowerCase();
  switch (u) {
    case "oz":
    case "ounce":
    case "ounces":
      return 0.5;
    case "cup":
    case "cups":
      return 0.25;
    case "tbsp":
    case "tablespoon":
    case "tablespoons":
      return 0.5;
    case "tsp":
    case "teaspoon":
    case "teaspoons":
      return 0.25;
    case "lb":
    case "lbs":
    case "pound":
    case "pounds":
      return 0.25;
    case "g":
    case "gram":
    case "grams":
      return 5;
    case "ml":
      return 15;
    case "whole":
    case "egg":
    case "eggs":
    case "clove":
    case "cloves":
    case "slice":
    case "slices":
    case "spear":
    case "spears":
    case "medium":
    case "scoop":
    case "scoops":
    case "fillet":
    case "fillets":
    case "piece":
    case "pieces":
    case "cube":
    case "cubes":
    case "patty":
    case "patties":
    case "link":
    case "links":
    case "strip":
    case "strips":
    case "pinch":
      return 1;
    default:
      return u.isEmpty ? 0.1 : 0.25;
  }
}

double _clean(double v) => (v * 1000).round() / 1000;

/// Nearest practical amount that is not above [raw], so rounding cannot
/// push a single ingredient past its share of the scale.
double snapQty(double raw, double step) {
  if (raw <= 0 || step <= 0) return 0;
  final nearest = _clean((raw / step).round() * step);
  if (nearest <= raw * 1.001 + 1e-6) return nearest;
  return _clean((raw / step + 1e-9).floor() * step);
}

bool portionsOverBudget(MacroSnapshot macros, SlotBudget budget) {
  if (budget.calories != null && budget.calories! > 0 && macros.calories > budget.calories!) return true;
  if (budget.protein != null && budget.protein! > 0 && macros.protein > budget.protein! + 0.05) return true;
  if (budget.carbs != null && budget.carbs! > 0 && macros.carbs > budget.carbs! + 0.05) return true;
  if (budget.fats != null && budget.fats! > 0 && macros.fats > budget.fats! + 0.05) return true;
  return false;
}

/// Scale every ingredient by the same factor, then snap to a practical
/// amount. The result stays at or under [budget]. Seasonings with no
/// calories keep their original amount. Scaling up stops at 3x so a tiny
/// recipe is not turned into an unrealistic pile; it can still land under
/// the budget. Scaling down continues until the meal is under.
ResizedPortions resizePortions({
  required List<Ingredient> ingredients,
  required int statedCalories,
  required double statedProtein,
  required double statedCarbs,
  required double statedFats,
  required SlotBudget budget,
}) {
  final base = [for (final ing in ingredients) ing];
  final computed = computeMacrosFromIngredients(base);
  final baseCal = (computed?.calories ?? statedCalories).toDouble();
  final baseP = computed?.protein ?? statedProtein;
  final baseC = computed?.carbs ?? statedCarbs;
  final baseF = computed?.fats ?? statedFats;
  final stated = computed ??
      MacroSnapshot(calories: statedCalories, protein: statedProtein, carbs: statedCarbs, fats: statedFats);

  if (!budget.constrains) {
    return ResizedPortions(scale: 1, ingredients: base, macros: stated);
  }

  double ratio(double value, double? cap) {
    if (cap == null || cap <= 0 || value <= 0) return double.infinity;
    return cap / value;
  }

  var scale = [
    ratio(baseCal, budget.calories?.toDouble()),
    ratio(baseP, budget.protein),
    ratio(baseC, budget.carbs),
    ratio(baseF, budget.fats),
  ].reduce((a, b) => a < b ? a : b);
  if (scale.isInfinite || scale.isNaN) scale = 1;
  if (scale > 3) scale = 3;

  for (var attempt = 0; attempt < 36; attempt++) {
    final rounded = _apply(base, scale);
    final macros = computeMacrosFromIngredients(rounded) ?? _scaledStated(stated, rounded, base);
    if (!portionsOverBudget(macros, budget)) {
      return ResizedPortions(scale: _clean(scale), ingredients: rounded, macros: macros);
    }
    scale *= 0.94;
  }

  final cleared = [
    for (final ing in base)
      (ing.macros == null || ing.macros!.cals <= 0) ? ing : ing.copyWith(qty: 0),
  ];
  return ResizedPortions(
    scale: 0,
    ingredients: cleared,
    macros: const MacroSnapshot(calories: 0, protein: 0, carbs: 0, fats: 0),
  );
}

List<Ingredient> _apply(List<Ingredient> base, double scale) {
  return [
    for (final ing in base)
      () {
        final qty = (ing.qty ?? 0).toDouble();
        final cals = ing.macros?.cals ?? 0;
        if (qty <= 0) return ing.copyWith(qty: 0);
        if (cals <= 0) return ing;
        return ing.copyWith(qty: snapQty(qty * scale, practicalStep(ing.unit)));
      }(),
  ];
}

/// When an ingredient has no per-unit macros, shrink the stated totals by
/// how far the countable amounts actually moved, and round down.
MacroSnapshot _scaledStated(MacroSnapshot stated, List<Ingredient> rounded, List<Ingredient> base) {
  double baseQty = 0, newQty = 0;
  for (var i = 0; i < base.length; i++) {
    final b = (base[i].qty ?? 0).toDouble();
    final n = (rounded[i].qty ?? 0).toDouble();
    if (b <= 0) continue;
    baseQty += b;
    newQty += n;
  }
  final ratio = baseQty == 0 ? 1.0 : newQty / baseQty;
  return MacroSnapshot(
    calories: (stated.calories * ratio).floor(),
    protein: (stated.protein * ratio * 10).floor() / 10,
    carbs: (stated.carbs * ratio * 10).floor() / 10,
    fats: (stated.fats * ratio * 10).floor() / 10,
  );
}

/// A client's copy of a library meal, fitted to [budget]. The library meal
/// itself is not modified. Base portions stay on [NutritionMeal.ingredients]
/// so the original recipe is still there; the fitted amounts live on
/// [NutritionMeal.scaledIngredients].
NutritionMeal mealFittedToBudget(MealDef meal, SlotBudget budget) {
  final resized = resizePortions(
    ingredients: meal.ingredients,
    statedCalories: meal.calories,
    statedProtein: meal.protein,
    statedCarbs: meal.carbs,
    statedFats: meal.fats,
    budget: budget,
  );
  return NutritionMeal(
    id: meal.id,
    name: meal.name,
    calories: meal.calories,
    protein: meal.protein,
    carbs: meal.carbs,
    fats: meal.fats,
    ingredients: meal.ingredients,
    instructions: meal.instructions,
    notes: meal.notes,
    isCustom: meal.isCustom,
    targetCalories: budget.calories,
    scale: resized.scale,
    scaledIngredients: resized.ingredients,
    scaledMacros: resized.macros,
    photoDataUrl: meal.photoDataUrl,
  );
}

/// Plain-text ingredient lines for the copy button.
String ingredientListAsText(List<Ingredient> ingredients) {
  return ingredients
      .map((ing) {
        final qty = ing.qty == null ? "" : " (${fmtQty(ing.qty)}${ing.unit != null && ing.unit!.isNotEmpty ? " ${ing.unit}" : ""})";
        return "- ${ing.item}$qty";
      })
      .join("\n");
}
