import "../../data/models/meal_def.dart";
import "../../data/models/nutrition_plan.dart";

/// One common food, with calories and macros for a single [unit].
///
/// The numbers are ordinary kitchen portions (one egg, one ounce, one cup)
/// so a food log and a homemade meal can multiply them by the amount.
class FoodItem {
  const FoodItem({
    required this.name,
    required this.unit,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fats,
    this.aliases = const [],
    this.mealTypes = const [],
    this.dietTags = const [],
  });

  final String name;
  final String unit;
  final double calories;
  final double protein;
  final double carbs;
  final double fats;
  final List<String> aliases;

  /// Empty means [inferredFoodMealTypes] decides. A food can be more than
  /// one meal, for example lunch and dinner.
  final List<String> mealTypes;

  /// Empty means [inferredFoodDietTags] decides. Explicit tags win.
  final List<String> dietTags;

  IngredientMacros get perUnit => IngredientMacros(cals: calories, p: protein, c: carbs, f: fats);

  bool matches(String query) {
    if (name.toLowerCase().contains(query)) return true;
    return aliases.any((a) => a.contains(query));
  }
}

const kFoods = <FoodItem>[
  FoodItem(name: "Eggs", unit: "whole", calories: 72, protein: 6.3, carbs: 0.4, fats: 4.8, aliases: ["egg"]),
  FoodItem(name: "Egg whites", unit: "whole", calories: 17, protein: 3.6, carbs: 0.2, fats: 0.1, aliases: ["egg white"]),
  FoodItem(name: "Chicken breast", unit: "oz", calories: 47, protein: 8.8, carbs: 0, fats: 1, aliases: ["chicken"]),
  FoodItem(name: "Sirloin steak", unit: "oz", calories: 55, protein: 7.7, carbs: 0, fats: 2.5, aliases: ["steak", "beef"]),
  FoodItem(name: "Ground turkey, 93%", unit: "oz", calories: 43, protein: 7.5, carbs: 0, fats: 1.3, aliases: ["turkey"]),
  FoodItem(name: "Salmon", unit: "oz", calories: 52, protein: 5.6, carbs: 0, fats: 3.4, aliases: ["salmon fillet"]),
  FoodItem(name: "Cod", unit: "oz", calories: 24, protein: 5.2, carbs: 0, fats: 0.2),
  FoodItem(name: "Shrimp", unit: "oz", calories: 28, protein: 6, carbs: 0.2, fats: 0.4),
  FoodItem(name: "Tuna, canned in water", unit: "oz", calories: 33, protein: 7.2, carbs: 0, fats: 0.3, aliases: ["tuna"]),
  FoodItem(name: "Firm tofu", unit: "oz", calories: 20, protein: 2.3, carbs: 0.5, fats: 1.2, aliases: ["tofu"]),
  FoodItem(name: "Turkey breast, sliced", unit: "slice", calories: 22, protein: 4.5, carbs: 0.5, fats: 0.3, aliases: ["deli turkey"]),
  FoodItem(name: "Bacon", unit: "slice", calories: 43, protein: 3, carbs: 0.1, fats: 3.3),
  FoodItem(name: "Protein powder", unit: "scoop", calories: 120, protein: 24, carbs: 3, fats: 1.5, aliases: ["whey", "protein"]),
  FoodItem(name: "Plain Greek yogurt", unit: "cup", calories: 130, protein: 23, carbs: 9, fats: 1, aliases: ["greek yogurt", "yogurt"]),
  FoodItem(name: "Cottage cheese, 2%", unit: "cup", calories: 183, protein: 24, carbs: 8, fats: 5, aliases: ["cottage cheese"]),
  FoodItem(name: "Cheddar cheese", unit: "oz", calories: 114, protein: 7, carbs: 0.4, fats: 9.4, aliases: ["cheese", "cheddar"]),
  FoodItem(name: "Mozzarella", unit: "oz", calories: 85, protein: 6.3, carbs: 0.6, fats: 6.3),
  FoodItem(name: "Milk, 2%", unit: "cup", calories: 122, protein: 8, carbs: 12, fats: 4.8, aliases: ["milk"]),
  FoodItem(name: "Unsweetened almond milk", unit: "cup", calories: 30, protein: 1, carbs: 1, fats: 2.5, aliases: ["almond milk"]),
  FoodItem(name: "Heavy cream", unit: "tbsp", calories: 51, protein: 0.4, carbs: 0.4, fats: 5.4),
  FoodItem(name: "Rolled oats", unit: "cup", calories: 300, protein: 10, carbs: 54, fats: 5, aliases: ["oats", "oatmeal"]),
  FoodItem(name: "Cooked white rice", unit: "cup", calories: 205, protein: 4.3, carbs: 45, fats: 0.4, aliases: ["rice", "white rice"]),
  FoodItem(name: "Cooked brown rice", unit: "cup", calories: 215, protein: 5, carbs: 45, fats: 1.8, aliases: ["brown rice"]),
  FoodItem(name: "Cooked quinoa", unit: "cup", calories: 222, protein: 8, carbs: 39, fats: 3.6, aliases: ["quinoa"]),
  FoodItem(name: "Whole-wheat bread", unit: "slice", calories: 81, protein: 4, carbs: 14, fats: 1.1, aliases: ["bread", "toast"]),
  FoodItem(name: "Whole-wheat tortilla", unit: "whole", calories: 130, protein: 4, carbs: 22, fats: 3.5, aliases: ["tortilla", "wrap"]),
  FoodItem(name: "Sweet potato", unit: "medium", calories: 103, protein: 2.3, carbs: 24, fats: 0.2),
  FoodItem(name: "White potato", unit: "medium", calories: 161, protein: 4.3, carbs: 37, fats: 0.2, aliases: ["potato"]),
  FoodItem(name: "Pasta, cooked", unit: "cup", calories: 220, protein: 8, carbs: 43, fats: 1.3, aliases: ["pasta", "noodles"]),
  FoodItem(name: "Banana", unit: "medium", calories: 105, protein: 1.3, carbs: 27, fats: 0.4),
  FoodItem(name: "Apple", unit: "medium", calories: 95, protein: 0.5, carbs: 25, fats: 0.3),
  FoodItem(name: "Blueberries", unit: "cup", calories: 84, protein: 1.1, carbs: 21, fats: 0.5),
  FoodItem(name: "Strawberries", unit: "cup", calories: 49, protein: 1, carbs: 12, fats: 0.5),
  FoodItem(name: "Mixed berries", unit: "cup", calories: 70, protein: 1, carbs: 17, fats: 0.5, aliases: ["berries"]),
  FoodItem(name: "Orange", unit: "medium", calories: 62, protein: 1.2, carbs: 15, fats: 0.2),
  FoodItem(name: "Olive oil", unit: "tbsp", calories: 119, protein: 0, carbs: 0, fats: 13.5),
  FoodItem(name: "Olive oil", unit: "tsp", calories: 40, protein: 0, carbs: 0, fats: 4.5),
  FoodItem(name: "Butter", unit: "tbsp", calories: 102, protein: 0.1, carbs: 0, fats: 11.5),
  FoodItem(name: "Almond butter", unit: "tbsp", calories: 98, protein: 3.4, carbs: 3, fats: 9),
  FoodItem(name: "Peanut butter", unit: "tbsp", calories: 94, protein: 4, carbs: 3.2, fats: 8),
  FoodItem(name: "Avocado", unit: "whole", calories: 234, protein: 2.9, carbs: 12.5, fats: 21, aliases: ["avocado"]),
  FoodItem(name: "Raw almonds", unit: "oz", calories: 164, protein: 6, carbs: 6, fats: 14, aliases: ["almonds"]),
  FoodItem(name: "Chia seeds", unit: "tbsp", calories: 58, protein: 2, carbs: 5, fats: 3.7, aliases: ["chia"]),
  FoodItem(name: "Broccoli", unit: "cup", calories: 31, protein: 2.5, carbs: 6, fats: 0.3),
  FoodItem(name: "Spinach", unit: "cup", calories: 7, protein: 0.9, carbs: 1.1, fats: 0.1),
  FoodItem(name: "Bell pepper", unit: "cup", calories: 30, protein: 1, carbs: 7, fats: 0.3, aliases: ["pepper"]),
  FoodItem(name: "Mixed greens", unit: "cup", calories: 8, protein: 0.6, carbs: 1.5, fats: 0.1, aliases: ["salad", "lettuce"]),
  FoodItem(name: "Cucumber", unit: "whole", calories: 45, protein: 2, carbs: 11, fats: 0.3),
  FoodItem(name: "Carrots", unit: "cup", calories: 52, protein: 1.2, carbs: 12, fats: 0.3, aliases: ["carrot"]),
  FoodItem(name: "Cherry tomatoes", unit: "cup", calories: 27, protein: 1.3, carbs: 5.8, fats: 0.3, aliases: ["tomato", "tomatoes"]),
  FoodItem(name: "Black beans", unit: "cup", calories: 227, protein: 15, carbs: 41, fats: 0.9, aliases: ["beans"]),
  FoodItem(name: "Chickpeas", unit: "cup", calories: 269, protein: 14.5, carbs: 45, fats: 4.2),
  FoodItem(name: "Red lentils, dry", unit: "cup", calories: 680, protein: 48, carbs: 116, fats: 2, aliases: ["lentils"]),
  FoodItem(name: "Honey", unit: "tbsp", calories: 64, protein: 0, carbs: 17, fats: 0),
  FoodItem(name: "Maple syrup", unit: "tbsp", calories: 52, protein: 0, carbs: 13.4, fats: 0),
  FoodItem(name: "Low-sodium soy sauce", unit: "tbsp", calories: 10, protein: 1.5, carbs: 1, fats: 0, aliases: ["soy sauce"]),
  FoodItem(name: "Salsa", unit: "tbsp", calories: 5, protein: 0.2, carbs: 1, fats: 0),
  FoodItem(name: "Hummus", unit: "tbsp", calories: 35, protein: 1, carbs: 3, fats: 2.2),
  FoodItem(name: "White rice cake", unit: "whole", calories: 35, protein: 0.7, carbs: 7.3, fats: 0.3, aliases: ["rice cake"]),
  FoodItem(name: "Granola", unit: "cup", calories: 597, protein: 14, carbs: 65, fats: 29, aliases: ["granola"]),
  FoodItem(name: "Corn tortilla", unit: "whole", calories: 52, protein: 1.4, carbs: 11, fats: 0.7, aliases: ["corn tortilla"]),
];

List<FoodItem> searchFoods(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return kFoods;
  final hits = kFoods.where((f) => f.matches(q)).toList();
  hits.sort((a, b) {
    final aStart = a.name.toLowerCase().startsWith(q) ? 0 : 1;
    final bStart = b.name.toLowerCase().startsWith(q) ? 0 : 1;
    if (aStart != bStart) return aStart.compareTo(bStart);
    return a.name.compareTo(b.name);
  });
  return hits;
}

/// Exact name, then a unique alias. Used when someone types an ingredient
/// instead of picking from the list. Returns null when nothing is sure.
FoodItem? matchFood(String name, {String? unit}) {
  final q = name.trim().toLowerCase();
  if (q.isEmpty) return null;
  final unitWanted = unit?.trim().toLowerCase();
  bool unitOk(FoodItem f) => unitWanted == null || unitWanted.isEmpty || f.unit.toLowerCase() == unitWanted;
  for (final f in kFoods) {
    if (f.name.toLowerCase() == q && unitOk(f)) return f;
  }
  final aliasHits = kFoods.where((f) => unitOk(f) && f.aliases.any((a) => a == q)).toList();
  if (aliasHits.length == 1) return aliasHits.first;
  return null;
}

IngredientMacros? macrosForNamedFood(String name, String unit) => matchFood(name, unit: unit)?.perUnit;

/// A food the client named closely enough to use its macro ratio.
///
/// Exact names and unique aliases win, including a leading amount
/// ("2 eggs") or a cooking word ("grilled chicken breast"). A mix of
/// foods ("chicken and rice") returns null.
FoodItem? matchFoodClosely(String name) {
  final q = _normFoodQuery(name);
  if (q.isEmpty) return null;
  for (final candidate in _foodQueryCandidates(q)) {
    final hit = _foodByNameOrAlias(candidate);
    if (hit != null) return hit;
  }
  return null;
}

const _foodFillerWords = {
  "grilled",
  "baked",
  "cooked",
  "fresh",
  "raw",
  "plain",
  "large",
  "small",
  "medium",
  "sliced",
  "chopped",
  "steamed",
  "roasted",
  "boiled",
  "fried",
  "organic",
  "boneless",
  "skinless",
  "whole",
  "half",
  "big",
  "mini",
};

final _foodQtyPrefix = RegExp(r"^(?:\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten)\s+");

String _normFoodQuery(String raw) {
  return raw.trim().toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), " ").replaceAll(RegExp(r"\s+"), " ").trim();
}

List<String> _foodQueryCandidates(String q) {
  final out = <String>[];
  void add(String? value) {
    final next = value?.trim() ?? "";
    if (next.isEmpty || out.contains(next)) return;
    out.add(next);
  }

  String? withoutQty(String value) {
    final stripped = value.replaceFirst(_foodQtyPrefix, "").trim();
    return stripped == value ? null : stripped;
  }

  String? withoutFiller(String value) {
    final parts = value.split(" ").where((word) => word.isNotEmpty && !_foodFillerWords.contains(word)).toList();
    if (parts.isEmpty) return null;
    final next = parts.join(" ");
    return next == value ? null : next;
  }

  String? singular(String value) {
    if (value.length < 4 || !value.endsWith("s") || value.endsWith("ss")) return null;
    if (value.endsWith("oes")) return value.substring(0, value.length - 2);
    return value.substring(0, value.length - 1);
  }

  add(q);
  add(withoutQty(q));
  add(withoutFiller(q));
  final qty = withoutQty(q);
  if (qty != null) add(withoutFiller(qty));
  final filler = withoutFiller(q);
  if (filler != null) add(withoutQty(filler));
  for (final candidate in List<String>.from(out)) {
    add(singular(candidate));
    final stripped = withoutQty(candidate);
    if (stripped != null) add(singular(stripped));
    final plain = withoutFiller(candidate);
    if (plain != null) add(singular(plain));
  }
  return out;
}

FoodItem? _foodByNameOrAlias(String q) {
  final byName = kFoods.where((food) => _normFoodQuery(food.name) == q).toList();
  if (byName.isNotEmpty) return _sameMacroRatio(byName) ? byName.first : null;
  final byAlias = kFoods.where((food) => food.aliases.any((alias) => _normFoodQuery(alias) == q)).toList();
  if (byAlias.isEmpty) return null;
  final names = byAlias.map((food) => _normFoodQuery(food.name)).toSet();
  if (names.length != 1) return null;
  return byAlias.first;
}

bool _sameMacroRatio(List<FoodItem> foods) {
  if (foods.length <= 1) return true;
  final base = foods.first;
  final baseSum = base.protein + base.carbs + base.fats;
  if (baseSum <= 0) {
    return foods.every((food) => food.protein + food.carbs + food.fats <= 0);
  }
  for (final food in foods.skip(1)) {
    final sum = food.protein + food.carbs + food.fats;
    if (sum <= 0) return false;
    if ((food.protein / sum - base.protein / baseSum).abs() > 0.02) return false;
    if ((food.carbs / sum - base.carbs / baseSum).abs() > 0.02) return false;
    if ((food.fats / sum - base.fats / baseSum).abs() > 0.02) return false;
  }
  return true;
}

const _glutenWords = [
  "wheat",
  "bread",
  "tortilla",
  "pasta",
  "noodle",
  "soy sauce",
  "barley",
  "rye",
  "flour",
  "couscous",
  "bagel",
  "pita",
  "naan",
  "seitan",
  "panko",
  "breadcrumb",
  "oat",
  "granola",
  "cracker",
  "bun",
  "crouton",
  "farro",
  "bulgur",
  "semolina",
  "malt",
  "orzo",
];

bool ingredientHasGluten(String name) {
  final n = name.toLowerCase();
  if (n.contains("gluten-free") || n.contains("gluten free")) return false;
  if (n.contains("corn tortilla")) return false;
  return _glutenWords.any(n.contains);
}

/// [filter] is a diet-tag key, or empty for no restriction.
///
/// Gluten-free trusts an explicit tag. Otherwise it hides a meal whose
/// ingredients look like they contain gluten. That check does not rewrite
/// the meal. Vegan meals also match vegetarian.
bool mealMatchesDiet(MealDef meal, String filter) {
  if (filter.isEmpty) return true;
  if (filter == "gluten-free") {
    if (meal.dietTags.contains("gluten-free")) return true;
    return !meal.ingredients.any((i) => ingredientHasGluten(i.item));
  }
  if (filter == "vegetarian") {
    return meal.dietTags.contains("vegetarian") || meal.dietTags.contains("vegan");
  }
  return meal.dietTags.contains(filter);
}

/// Slots a catalog meal belongs to. Lunch and dinner count as both unless
/// [MealDef.alsoFor] says otherwise. A smoothie also counts as a snack.
List<String> mealSlots(MealDef meal) {
  if (meal.alsoFor.isNotEmpty) {
    return {meal.mealType, ...meal.alsoFor}.toList();
  }
  if (meal.mealType == "lunch" || meal.mealType == "dinner") {
    return ["lunch", "dinner"];
  }
  if (meal.mealType == "smoothies") return ["smoothies", "snacks"];
  return [meal.mealType];
}

List<String> foodMealTypes(FoodItem food) {
  if (food.mealTypes.isNotEmpty) return food.mealTypes;
  final n = food.name.toLowerCase();
  const breakfast = ["egg", "oat", "yogurt", "bacon", "granola"];
  const snacks = ["almond", "apple", "hummus", "rice cake", "berries", "banana"];
  if (breakfast.any(n.contains)) return ["breakfast"];
  if (snacks.any(n.contains)) return ["snacks", "breakfast"];
  return ["lunch", "dinner"];
}

List<String> foodDietTags(FoodItem food) {
  if (food.dietTags.isNotEmpty) return food.dietTags;
  final n = food.name.toLowerCase();
  const meat = ["chicken", "steak", "beef", "turkey", "bacon", "salmon", "tuna", "shrimp", "cod", "fish"];
  const dairy = ["yogurt", "cheese", "milk", "cream"];
  final dairyHit = dairy.any(n.contains) || (n.contains("butter") && !n.contains("almond") && !n.contains("peanut"));
  final meatHit = meat.any(n.contains);
  final tags = <String>["omnivore"];
  if (!meatHit) tags.add("vegetarian");
  if (!meatHit && !dairyHit && !n.contains("egg") && !n.contains("honey")) tags.add("vegan");
  if (!dairyHit) tags.add("dairy-free");
  if (!ingredientHasGluten(food.name)) tags.add("gluten-free");
  if (food.carbs <= 8) tags.add("keto");
  return tags;
}

bool foodMatchesDiet(FoodItem food, String filter) {
  if (filter.isEmpty) return true;
  final tags = foodDietTags(food);
  if (filter == "vegetarian") return tags.contains("vegetarian") || tags.contains("vegan");
  return tags.contains(filter);
}

bool foodMatchesMeal(FoodItem food, String meal) {
  if (meal.isEmpty || meal == "all") return true;
  return foodMealTypes(food).contains(meal);
}

bool mealMatchesSlot(MealDef meal, String mealFilter) {
  if (mealFilter.isEmpty || mealFilter == "all") return true;
  return mealSlots(meal).contains(mealFilter);
}

