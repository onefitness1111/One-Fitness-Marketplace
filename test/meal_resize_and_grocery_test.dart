import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/meal_resize.dart";
import "package:onefitness/core/utils/nutrition_utils.dart";
import "package:onefitness/data/models/nutrition_plan.dart";

Ingredient steak(num oz) => Ingredient(
      item: "Sirloin steak",
      qty: oz,
      unit: "oz",
      category: "proteins",
      macros: const IngredientMacros(cals: 55, p: 7.7, c: 0, f: 2.5),
    );

Ingredient eggs(num count) => Ingredient(
      item: "Eggs",
      qty: count,
      unit: "whole",
      category: "proteins",
      macros: const IngredientMacros(cals: 72, p: 6.3, c: 0.4, f: 4.8),
    );

Ingredient rice(num cups) => Ingredient(
      item: "Cooked white rice",
      qty: cups,
      unit: "cup",
      category: "grains",
      macros: const IngredientMacros(cals: 205, p: 4.3, c: 45, f: 0.4),
    );

Ingredient pinch() => const Ingredient(
      item: "Salt & pepper",
      qty: 1,
      unit: "pinch",
      category: "spices",
      macros: IngredientMacros(cals: 0, p: 0, c: 0, f: 0),
    );

NutritionMeal mealOf(List<Ingredient> ings, {List<Ingredient>? scaled}) {
  var calories = 0;
  var protein = 0.0, carbs = 0.0, fats = 0.0;
  for (final ing in ings) {
    final qty = (ing.qty ?? 0).toDouble();
    calories += ((ing.macros?.cals ?? 0) * qty).round();
    protein += (ing.macros?.p ?? 0) * qty;
    carbs += (ing.macros?.c ?? 0) * qty;
    fats += (ing.macros?.f ?? 0) * qty;
  }
  return NutritionMeal(
    id: "t",
    name: "Test meal",
    calories: calories,
    protein: protein,
    carbs: carbs,
    fats: fats,
    ingredients: ings,
    scaledIngredients: scaled,
  );
}

void main() {
  test("a resized meal never goes over the calorie or macro budget", () {
    final base = [steak(6), eggs(3), rice(1), pinch()];
    final budget = const SlotBudget(calories: 350, protein: 30, carbs: 40, fats: 12);
    final resized = resizePortions(
      ingredients: base,
      statedCalories: 900,
      statedProtein: 80,
      statedCarbs: 50,
      statedFats: 30,
      budget: budget,
    );

    expect(resized.macros.calories, lessThanOrEqualTo(350));
    expect(resized.macros.protein, lessThanOrEqualTo(30.05));
    expect(resized.macros.carbs, lessThanOrEqualTo(40.05));
    expect(resized.macros.fats, lessThanOrEqualTo(12.05));
    expect(base.first.qty, 6);
    expect(base[1].qty, 3);
  });

  test("portions stay proportional and use practical amounts", () {
    final base = [steak(6), eggs(2), rice(1)];
    final resized = resizePortions(
      ingredients: base,
      statedCalories: 0,
      statedProtein: 0,
      statedCarbs: 0,
      statedFats: 0,
      budget: const SlotBudget(calories: 500),
    );

    final steakQty = resized.ingredients[0].qty!.toDouble();
    final eggQty = resized.ingredients[1].qty!.toDouble();
    final riceQty = resized.ingredients[2].qty!.toDouble();

    expect(steakQty % 0.5, 0);
    expect(eggQty % 1, 0);
    expect(riceQty % 0.25, 0);

    for (var i = 0; i < base.length; i++) {
      final original = base[i].qty!.toDouble();
      final raw = original * resized.scale;
      final step = practicalStep(base[i].unit);
      expect((resized.ingredients[i].qty!.toDouble() - raw).abs(), lessThanOrEqualTo(step + 0.001));
    }
  });

  test("6 oz of steak fitted upward lands on 8 oz and not over", () {
    final resized = resizePortions(
      ingredients: [steak(6), pinch()],
      statedCalories: 330,
      statedProtein: 46.2,
      statedCarbs: 0,
      statedFats: 15,
      budget: const SlotBudget(calories: 440),
    );

    expect(resized.ingredients.first.qty, 8);
    expect(resized.ingredients.last.qty, 1);
    expect(resized.macros.calories, lessThanOrEqualTo(440));
    expect(resized.macros.calories, greaterThanOrEqualTo(400));
  });

  test("rounding down keeps a too-big meal under the budget", () {
    final resized = resizePortions(
      ingredients: [eggs(3)],
      statedCalories: 216,
      statedProtein: 18.9,
      statedCarbs: 1.2,
      statedFats: 14.4,
      budget: const SlotBudget(calories: 150),
    );
    expect(resized.ingredients.single.qty, 2);
    expect(resized.macros.calories, lessThanOrEqualTo(150));
  });

  test("the grocery list adds the fitted amounts, not the base recipe", () {
    final fitted = mealOf([steak(6)], scaled: [steak(8)]);
    final another = mealOf([steak(4)]);
    final lines = buildGroceryList([fitted, another]);

    expect(lines, hasLength(1));
    expect(lines.single.item, "Sirloin steak");
    expect(lines.single.unit, "oz");
    expect(lines.single.qty, 12);
  });

  test("one chosen meal shows its fitted steak, not the 6 oz base", () {
    final lines = buildGroceryList([mealOf([steak(6)], scaled: [steak(8)])]);
    expect(lines.single.qty, 8);
  });
}
