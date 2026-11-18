import "../../data/models/ingredient_grocery_item.dart";
import "../../data/models/nutrition_plan.dart";
import "nutrition_helpers.dart" show effectiveIngredients;

/// Mirrors nutritionHelpers.js `macroShortLabel`.
String macroShortLabel(String key) => const {
      "protein": "Pg",
      "carbs": "Cg",
      "fats": "Fg",
      "calories": "Cal",
      "water": "H₂O",
    }[key] ??
    key;

/// (key, label, unit) rows — mirrors schemas.js `MACRO_FIELDS`.
const kMacroFields = [
  ("calories", "Calories", "kcal"),
  ("protein", "Protein %", "%"),
  ("carbs", "Carbs %", "%"),
  ("fats", "Fat %", "%"),
  ("water", "Water", ""),
];

class TargetMatch {
  const TargetMatch({required this.delta, required this.pct, required this.color});
  final int delta;
  final int pct;
  final int color; // ARGB packed elsewhere via Color(); kept as int to avoid a Flutter import here
}

/// Combined grocery lines. Uses each meal's fitted amounts when the client
/// resized it, and the original amounts when nobody did. The same ingredient
/// and unit are added together.
List<IngredientGroceryItem> buildGroceryList(List<NutritionMeal> meals) {
  final byKey = <String, IngredientGroceryItem>{};
  for (final meal in meals) {
    for (final ing in effectiveIngredients(meal)) {
      final key = "${ing.item.trim().toLowerCase()}|${(ing.unit ?? '').trim().toLowerCase()}";
      final existing = byKey[key];
      if (existing != null && existing.qty != null && ing.qty != null) {
        byKey[key] = IngredientGroceryItem(item: ing.item, qty: existing.qty! + ing.qty!, unit: ing.unit);
      } else {
        byKey[key] ??= IngredientGroceryItem(item: ing.item, qty: ing.qty, unit: ing.unit);
      }
    }
  }
  final items = byKey.values.toList()..sort((a, b) => a.item.compareTo(b.item));
  return items;
}

/// Mirrors nutritionHelpers.js `fmtQty` — whole numbers with no decimal,
/// otherwise rounded to 2 decimal places.
String fmtQty(num? qty) {
  if (qty == null) return "";
  if (qty % 1 == 0) return qty.toInt().toString();
  final rounded = (qty * 100).round() / 100;
  return rounded.toString();
}
