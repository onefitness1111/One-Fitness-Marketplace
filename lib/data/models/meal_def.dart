import "nutrition_plan.dart";

/// Mirrors one entry in the meal database catalog (src/data/mealDatabase.js).
class MealDef {
  const MealDef({
    required this.id,
    required this.name,
    required this.mealType, // "breakfast" | "lunch" | "dinner" | "snacks" | "smoothies"
    this.calories = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fats = 0,
    this.ingredients = const [],
    this.instructions,
    this.notes,
    this.dietTags = const [],
    this.alsoFor = const [],
    this.isCustom = false,
    this.photoDataUrl,
  });

  final String id;
  final String name;
  final String mealType;
  final int calories;
  final double protein;
  final double carbs;
  final double fats;
  final List<Ingredient> ingredients;
  final String? instructions;
  final String? notes;
  final List<String> dietTags;

  /// Extra meal slots besides [mealType]. Empty means lunch and dinner
  /// count as both, and a smoothie also counts as a snack.
  final List<String> alsoFor;
  final bool isCustom;

  /// Optional compressed photo (`data:image/jpeg;base64,...`). Absent on
  /// every built-in meal and on meals saved before photos existed.
  final String? photoDataUrl;
}

/// Mirrors mealDatabase.js `DIET_TAGS` — the real diet-filter taxonomy (raw
/// keys stored on each meal/on client diet filters; `label` is display-only).
const kDietTags = <(String, String)>[
  ("omnivore", "Omnivore / No Restriction"),
  ("vegetarian", "Vegetarian"),
  ("vegan", "Vegan"),
  ("pescatarian", "Pescatarian"),
  ("halal", "Halal"),
  ("kosher", "Kosher"),
  ("no-pork", "No Pork"),
  ("no-beef", "No Beef"),
  ("keto", "Keto"),
  ("paleo", "Paleo"),
  ("high-protein", "High-Protein"),
  ("low-carb", "Low-Carb"),
  ("gluten-free", "Gluten-free"),
];

/// Filters on the client's meal picker. One at a time. An empty key means
/// show every meal of that slot.
const kClientDietFilters = <(String, String)>[
  ("", "No restrictions"),
  ("vegetarian", "Vegetarian"),
  ("vegan", "Vegan"),
  ("keto", "Keto"),
  ("paleo", "Paleo"),
  ("kosher", "Kosher"),
  ("gluten-free", "Gluten-free"),
];

String dietTagLabel(String key) => kDietTags.firstWhere((t) => t.$1 == key, orElse: () => (key, key)).$2;

/// Mirrors mealDatabase.js `INGREDIENT_CATEGORIES` — grocery-list bucketing
/// order/labels.
const kIngredientCategories = <(String, String)>[
  ("proteins", "Proteins"),
  ("vegetables", "Vegetables"),
  ("fruits", "Fruits"),
  ("grains", "Grains & Starches"),
  ("dairy", "Dairy & Alternatives"),
  ("fats", "Healthy Fats"),
  ("pantry", "Pantry Items"),
  ("spices", "Seasonings & Spices"),
  ("beverages", "Beverages"),
];
