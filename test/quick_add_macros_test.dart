import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/nutrition/food_log_view.dart";
import "package:onefitness/core/nutrition/quick_add_macros.dart";
import "package:onefitness/core/utils/food_catalog.dart";

void main() {
  test("typed macros are kept and the line is not estimated", () {
    final macros = mergeQuickAddMacros(
      calories: 100,
      protein: 1,
      carbs: 2,
      fats: 3,
      sourceProtein: 50,
      sourceCarbs: 50,
      sourceFats: 50,
    )!;
    expect(macros.protein, 1);
    expect(macros.carbs, 2);
    expect(macros.fats, 3);
    expect(macros.estimated, isFalse);

    final item = foodLogItemFromQuickAdd(
      name: "Snack",
      calories: 100,
      macros: macros,
      idSuffix: "1",
    );
    expect(item.calories, 100);
    expect(item.protein, 1);
    expect(foodLogEntryIsEstimated(item), isFalse);
    expect(item.id, "log-1");
  });

  test("a typed zero is kept when the other macros are filled", () {
    final macros = mergeQuickAddMacros(
      calories: 144,
      protein: 0,
      carbs: null,
      fats: null,
      sourceProtein: 6.3,
      sourceCarbs: 0.4,
      sourceFats: 4.8,
    )!;
    expect(macros.protein, 0);
    expect(macros.carbs, greaterThan(0));
    expect(macros.fats, greaterThan(0));
    expect(macros.estimated, isTrue);
    expect((macros.macroCalories - 144).abs(), lessThan(1.5));
  });

  test("blank macros are filled and scaled to the typed calories", () {
    final macros = mergeQuickAddMacros(
      calories: 400,
      protein: null,
      carbs: null,
      fats: null,
      sourceProtein: 10,
      sourceCarbs: 20,
      sourceFats: 5,
    )!;
    expect(macros.estimated, isTrue);
    expect(macros.protein, closeTo(24.2, 0.15));
    expect(macros.carbs, closeTo(48.5, 0.15));
    expect(macros.fats, closeTo(12.1, 0.15));
    expect((macros.macroCalories - 400).abs(), lessThan(1.5));

    final item = foodLogItemFromQuickAdd(
      name: "Bowl",
      calories: 400,
      macros: macros,
      idSuffix: "9",
    );
    expect(foodLogEntryIsEstimated(item), isTrue);
    expect(item.id, "est-9");
    expect(item.unit, "serving");
    expect(item.calories, 400);
  });

  test("only the blank macros change", () {
    final macros = mergeQuickAddMacros(
      calories: 300,
      protein: null,
      carbs: 20,
      fats: 10,
      sourceProtein: 10,
      sourceCarbs: 10,
      sourceFats: 10,
    )!;
    expect(macros.protein, 32.5);
    expect(macros.carbs, 20);
    expect(macros.fats, 10);
    expect(macros.estimated, isTrue);
    expect(macros.macroCalories, 300);
  });

  test("typed protein stays put when carbs and fat were blank", () {
    final macros = mergeQuickAddMacros(
      calories: 500,
      protein: 30,
      carbs: null,
      fats: null,
      sourceProtein: 8.8,
      sourceCarbs: 0,
      sourceFats: 1,
    )!;
    expect(macros.protein, 30);
    expect(macros.carbs, 0);
    expect(macros.fats, closeTo(42.2, 0.15));
    expect(macros.estimated, isTrue);
    expect((macros.macroCalories - 500).abs(), lessThan(1.5));
  });

  test(
    "a known food with no grams in the blank macros keeps those at zero",
    () {
      final macros = mergeQuickAddMacros(
        calories: 90,
        protein: null,
        carbs: null,
        fats: 10,
        sourceProtein: 0,
        sourceCarbs: 0,
        sourceFats: 13.5,
      )!;
      expect(macros.protein, 0);
      expect(macros.carbs, 0);
      expect(macros.fats, 10);
      expect(macros.estimated, isTrue);
    },
  );

  test(
    "typed macros that already cover the calories leave the blanks at zero",
    () {
      final macros = mergeQuickAddMacros(
        calories: 200,
        protein: 80,
        carbs: null,
        fats: null,
        sourceProtein: 10,
        sourceCarbs: 10,
        sourceFats: 10,
      )!;
      expect(macros.protein, 80);
      expect(macros.carbs, 0);
      expect(macros.fats, 0);
      expect(macros.estimated, isTrue);
    },
  );

  test("an empty source cannot fill a blank", () {
    expect(
      mergeQuickAddMacros(
        calories: 400,
        protein: null,
        carbs: null,
        fats: null,
        sourceProtein: 0,
        sourceCarbs: 0,
        sourceFats: 0,
      ),
      isNull,
    );
  });

  test("a close food name fills blanks from the search list", () {
    expect(matchFoodClosely("Banana")?.name, "Banana");
    expect(matchFoodClosely("bananas")?.name, "Banana");
    expect(matchFoodClosely("2 eggs")?.name, "Eggs");
    expect(matchFoodClosely("grilled chicken breast")?.name, "Chicken breast");
    expect(matchFoodClosely("olive oil")?.name, "Olive oil");
    expect(matchFoodClosely("chicken and rice"), isNull);
    expect(matchFoodClosely("dragonfruit smoothie"), isNull);

    final banana = localQuickAddMacros(
      name: "bananas",
      calories: 210,
      protein: null,
      carbs: null,
      fats: null,
    )!;
    expect(banana.estimated, isTrue);
    expect(banana.carbs, greaterThan(banana.protein));
    expect((banana.macroCalories - 210).abs(), lessThan(1.5));

    final typed = localQuickAddMacros(
      name: "banana",
      calories: 210,
      protein: 9,
      carbs: 1,
      fats: 1,
    )!;
    expect(typed.estimated, isFalse);
    expect(typed.protein, 9);
    expect(typed.carbs, 1);
    expect(typed.fats, 1);

    final zero = localQuickAddMacros(
      name: "anything",
      calories: 0,
      protein: null,
      carbs: 4,
      fats: null,
    )!;
    expect(zero.protein, 0);
    expect(zero.carbs, 4);
    expect(zero.fats, 0);
    expect(zero.estimated, isTrue);

    expect(
      localQuickAddMacros(
        name: "chicken and rice",
        calories: 500,
        protein: null,
        carbs: null,
        fats: null,
      ),
      isNull,
    );
  });

  test("a server estimate fills only the blanks", () {
    final macros = macrosFromServerEstimate(
      calories: 400,
      protein: 25,
      carbs: null,
      fats: null,
      response: {"ok": true, "protein": 10, "carbs": 20, "fats": 5},
    )!;
    expect(macros.protein, 25);
    expect(macros.carbs, greaterThan(0));
    expect(macros.fats, greaterThan(0));
    expect(macros.estimated, isTrue);
    expect((macros.macroCalories - 400).abs(), lessThan(1.5));

    expect(
      macrosFromServerEstimate(
        calories: 400,
        protein: null,
        carbs: null,
        fats: null,
        response: {"ok": false, "error": "offline"},
      ),
      isNull,
    );
    expect(
      macrosFromServerEstimate(
        calories: 400,
        protein: null,
        carbs: null,
        fats: null,
        response: {"ok": true, "protein": 0, "carbs": 0, "fats": 0},
      ),
      isNull,
    );
  });

  test("blank text is not a typed zero", () {
    expect(readQuickAddMacro(""), isNull);
    expect(readQuickAddMacro("  "), isNull);
    expect(readQuickAddMacro("abc"), isNull);
    expect(readQuickAddMacro("0"), 0);
    expect(readQuickAddMacro("12.5"), 12.5);
  });
}
