import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/food_catalog.dart";
import "package:onefitness/data/models/meal_def.dart";

void main() {
  test("lunch and dinner count as both unless the meal says otherwise", () {
    const lunch = MealDef(id: "l", name: "Bowl", mealType: "lunch");
    expect(mealSlots(lunch), ["lunch", "dinner"]);

    const onlyLunch = MealDef(id: "l2", name: "Soup", mealType: "lunch", alsoFor: ["snacks"]);
    expect(mealSlots(onlyLunch), containsAll(["lunch", "snacks"]));
    expect(mealSlots(onlyLunch), isNot(contains("dinner")));
  });

  test("a breakfast search hides a dinner-only plate and a steak", () {
    const dinner = MealDef(id: "d", name: "Salmon", mealType: "dinner", dietTags: ["omnivore"]);
    const eggs = FoodItem(name: "Eggs", unit: "whole", calories: 72, protein: 6, carbs: 0, fats: 5);
    const steak = FoodItem(name: "Sirloin steak", unit: "oz", calories: 55, protein: 8, carbs: 0, fats: 2);

    expect(mealMatchesSlot(dinner, "breakfast"), isFalse);
    expect(mealMatchesSlot(dinner, "dinner"), isTrue);
    expect(mealMatchesSlot(dinner, "all"), isTrue);
    expect(foodMatchesMeal(eggs, "breakfast"), isTrue);
    expect(foodMatchesMeal(steak, "breakfast"), isFalse);
    expect(foodMatchesDiet(steak, "vegetarian"), isFalse);
    expect(foodMatchesDiet(eggs, "vegetarian"), isTrue);
    expect(foodDietTags(const FoodItem(name: "Spinach", unit: "cup", calories: 7, protein: 1, carbs: 1, fats: 0)), contains("dairy-free"));
  });

  test("gluten-free hides bread and keeps rice", () {
    const bread = FoodItem(name: "Whole-wheat bread", unit: "slice", calories: 80, protein: 4, carbs: 14, fats: 1);
    const rice = FoodItem(name: "Cooked white rice", unit: "cup", calories: 205, protein: 4, carbs: 45, fats: 0);
    expect(foodMatchesDiet(bread, "gluten-free"), isFalse);
    expect(foodMatchesDiet(rice, "gluten-free"), isTrue);
  });
}
