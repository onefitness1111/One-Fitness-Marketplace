import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/meal_resize.dart";
import "../../../core/utils/nutrition_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/food_log.dart";
import "../../../data/models/ingredient_grocery_item.dart";
import "../../../data/models/meal_def.dart";
import "../../../data/models/nutrition_plan.dart";
import "../../../data/providers/client_providers.dart";
import "../../../core/legal/health_sources.dart";
import "../../../core/widgets/source_citations.dart";
import "../../../core/utils/nutrition_helpers.dart"
    show effectiveIngredients, effectiveMacros;
import "add_meal_screen.dart";
import "food_log_section.dart";
import "meal_ingredient_editor.dart";
import "client_meal_picker.dart";
import "restaurant_sheet.dart";

/// Client nutrition page. One day and one training/rest toggle drive the
/// targets, the reference calorie budget, and the food log. Guidelines,
/// then the log, the uploaded meals, or the grocery list.
class NutritionTab extends ConsumerStatefulWidget {
  const NutritionTab({super.key});

  @override
  ConsumerState<NutritionTab> createState() => _NutritionTabState();
}

class _NutritionTabState extends ConsumerState<NutritionTab> {
  DateTime _day = DateTime.now();
  String _dayType = "training";
  bool _copied = false;
  bool _guidelinesOpen = false;

  /// 0 log, 1 uploaded meals, 2 grocery list.
  int _panel = 0;

  String get _dateLabel {
    final now = DateTime.now();
    if (_day.year == now.year && _day.month == now.month && _day.day == now.day) {
      return "Today";
    }
    return "${_day.month}/${_day.day}";
  }

  /// Saves the client's own picks for one category, and keeps the screen in
  /// step whether or not the write reaches the server.
  Future<void> _saveChoices(String category, List<NutritionMeal> meals) async {
    final id = ref.read(clientInfoProvider).id;
    final next = {...ref.read(clientRecordProvider).myMeals, category: meals};
    ref
        .read(clientRecordProvider.notifier)
        .update((r) => r.copyWith(myMeals: next));
    try {
      await SupabaseService.updateClientChosenMeals(id, next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't save your meal — check your connection and try again.",
            ),
          ),
        );
      }
    }
  }

  SlotBudget _slotBudget(String category) {
    final n = ref.read(clientRecordProvider).nutrition;
    if (n == null) return const SlotBudget();
    final targets = _dayType == "training" ? n.trainingTargets : n.restTargets;
    final budgets = _dayType == "training"
        ? n.mealBudgets.training
        : n.mealBudgets.rest;
    return SlotBudget.forSlot(
      slotCalories: int.tryParse(budgets[category] ?? ""),
      proteinPct: targets.protein,
      carbsPct: targets.carbs,
      fatsPct: targets.fats,
    );
  }

  Future<void> _pickMeal(String category, String label) async {
    final picked = await showClientMealPicker(
      context,
      ref,
      category: category,
      label: label,
      budget: _slotBudget(category),
    );
    if (picked == null) return;
    final current =
        ref.read(clientRecordProvider).myMeals[category] ??
        const <NutritionMeal>[];
    if (current.any((m) => m.id == picked.id)) return;
    await _saveChoices(category, [...current, picked]);
  }

  Future<void> _addOwnMeal(String category, String label) async {
    final created = await Navigator.of(context).push<MealDef>(
      MaterialPageRoute(
        builder: (_) => AddMealScreen(mealType: category, label: label),
      ),
    );
    if (created == null) return;
    final fitted = mealFittedToBudget(created, _slotBudget(category));
    final current =
        ref.read(clientRecordProvider).myMeals[category] ??
        const <NutritionMeal>[];
    await _saveChoices(category, [...current, fitted]);
  }

  /// Copies a coach meal into the client's own list and fits the portions.
  /// The meal on the program is left as it was uploaded.
  Future<void> _fitUploaded(String category, NutritionMeal meal) async {
    final source = MealDef(
      id: "fit-${DateTime.now().microsecondsSinceEpoch}",
      name: meal.name,
      mealType: category,
      calories: meal.calories,
      protein: meal.protein,
      carbs: meal.carbs,
      fats: meal.fats,
      ingredients: meal.ingredients,
      instructions: meal.instructions,
      notes: meal.notes,
      isCustom: meal.isCustom,
      photoDataUrl: meal.photoDataUrl,
    );
    final fitted = mealFittedToBudget(source, _slotBudget(category));
    final current =
        ref.read(clientRecordProvider).myMeals[category] ??
        const <NutritionMeal>[];
    await _saveChoices(category, [...current, fitted]);
  }

  Future<void> _restaurant(String category, String label) async {
    final item = await showRestaurantSheet(
      context,
      slot: category,
      label: label,
      budget: _slotBudget(category),
    );
    if (item == null) return;
    final id = ref.read(clientInfoProvider).id;
    final today = foodLogDate(DateTime.now());
    final next = ref
        .read(clientRecordProvider)
        .foodLog
        .add(today, category, item);
    ref
        .read(clientRecordProvider.notifier)
        .update((r) => r.copyWith(foodLog: next));
    try {
      await SupabaseService.updateClientFoodLog(id, next);
      try {
        final fresh = await SupabaseService.loadMeritBadgesFor(id);
        ref.read(earnedBadgesProvider.notifier).replaceForClient(id, fresh);
      } catch (_) {}
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save that. Try again.")),
      );
    }
  }

  /// Lets the client change how much of each ingredient is in a meal they
  /// picked. Saved as per-ingredient overrides, so the original recipe is
  /// never overwritten and the totals recompute from the new amounts.
  Future<void> _editMeal(String category, NutritionMeal meal) async {
    final n = ref.read(clientRecordProvider).nutrition;
    final budget = int.tryParse(
      ((_dayType == "training"
                  ? n?.mealBudgets.training
                  : n?.mealBudgets.rest) ??
              const {})[category] ??
          "",
    );
    final updated = await showMealIngredientEditor(
      context,
      meal: meal,
      budget: budget,
    );
    if (updated == null) return;
    final current =
        ref.read(clientRecordProvider).myMeals[category] ??
        const <NutritionMeal>[];
    await _saveChoices(
      category,
      current.map((m) => m.id == updated.id ? updated : m).toList(),
    );
  }

  Future<void> _removeChoice(String category, NutritionMeal meal) async {
    final current =
        ref.read(clientRecordProvider).myMeals[category] ??
        const <NutritionMeal>[];
    await _saveChoices(
      category,
      current.where((m) => m.id != meal.id).toList(),
    );
  }

  void _copyGrocery(List<IngredientGroceryItem> grocery) {
    final text = grocery
        .map(
          (it) =>
              "- ${it.item}${it.qty != null ? " (${fmtQty(it.qty)}${it.unit != null ? ' ${it.unit}' : ''})" : ""}",
        )
        .join("\n");
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientRecordProvider);
    final n = client.nutrition;
    final dayHeader = _DayHeader(
      label: _dateLabel,
      onPrevious: () =>
          setState(() => _day = _day.subtract(const Duration(days: 1))),
      onNext: () => setState(() => _day = _day.add(const Duration(days: 1))),
    );

    if (n == null) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          dayHeader,
          FoodLogSection(day: _day, dayType: _dayType),
          const HintBox(
            text:
                "Complete your Nutritional Assessment (under Forms) so your coach can build your nutrition program. It'll show up here. You can still log food above.",
          ),
        ],
      );
    }

    final targets = _dayType == "training"
        ? n.trainingTargets.asMap()
        : n.restTargets.asMap();
    final hasTargets = targets.values.any((v) => v != null && v.isNotEmpty);
    final dailyCal = int.tryParse(targets["calories"] ?? "") ?? 0;
    final budgets = _dayType == "training"
        ? n.mealBudgets.training
        : n.mealBudgets.rest;

    // The grocery list covers what the client actually plans to eat, so
    // their own picks belong in it as much as the coach's suggestions.
    final allMeals = [
      ...n.breakfast,
      ...n.lunch,
      ...n.dinner,
      ...n.snacks,
      ...n.smoothies,
      ...client.myMeals.values.expand((m) => m),
    ];
    final grocery = buildGroceryList(allMeals);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          dayHeader,
          const SizedBox(height: 4),
          SegmentedToggle(
            labels: const ["Training Day", "Rest Day"],
            index: _dayType == "training" ? 0 : 1,
            onChanged: (index) => setState(() => _dayType = index == 0 ? "training" : "rest"),
          ),
          if (hasTargets) ...[
            const SizedBox(height: 16),
            SectionLabel(
              "${_dayType == 'training' ? 'Training' : 'Rest'} Day Targets",
            ),
            _TargetStrip(targets: targets),
            const SizedBox(height: 16),
            _CalorieBudgetPanel(mealBudgets: budgets, dailyCalTarget: dailyCal),
          ],
          if (n.guidelines != null && n.guidelines!.isNotEmpty) ...[
            const SizedBox(height: 16),
            _GuidelinesCard(
              text: n.guidelines!,
              open: _guidelinesOpen,
              onToggle: () =>
                  setState(() => _guidelinesOpen = !_guidelinesOpen),
            ),
          ],
          const SizedBox(height: 16),
          SegmentedToggle(
            labels: const ["Log food", "Meals", "Grocery list"],
            index: _panel,
            fontSize: 11,
            itemKeys: const [
              Key("nutrition-segment-log"),
              Key("nutrition-segment-meals"),
              Key("nutrition-segment-grocery"),
            ],
            onChanged: (value) => setState(() => _panel = value),
          ),
          const SizedBox(height: 14),
          if (_panel == 0) FoodLogSection(day: _day, dayType: _dayType),
          if (_panel == 1) ...[
            // The client picks their own meals for every category, alongside
            // whatever their coach suggested. Snacks and smoothies
            // used to be one read-only section that disappeared entirely when
            // the program suggested none — so a client could never add their
            // own. Each category is now separately choosable and always shown.
            //
            // Choosing is never gated on the program having calorie budgets:
            // a budget makes the picker smarter (it can sort and filter by
            // "fits this meal"), but its absence is no reason to stop someone
            // deciding what they eat.
            for (final c in const [
              ("breakfast", "Breakfast"),
              ("lunch", "Lunch"),
              ("dinner", "Dinner"),
              ("snacks", "Snacks"),
              ("smoothies", "Smoothies"),
            ])
              _MealSection(
                title: c.$2,
                meals: switch (c.$1) {
                  "breakfast" => n.breakfast,
                  "lunch" => n.lunch,
                  "dinner" => n.dinner,
                  "snacks" => n.snacks,
                  _ => n.smoothies,
                },
                chosen: client.myMeals[c.$1] ?? const [],
                budget: int.tryParse(budgets[c.$1] ?? ""),
                onChoose: () => _pickMeal(c.$1, c.$2),
                onAddMeal: () => _addOwnMeal(c.$1, c.$2),
                onRestaurant:
                    c.$1 == "breakfast" || c.$1 == "lunch" || c.$1 == "dinner"
                    ? () => _restaurant(c.$1, c.$2)
                    : null,
                onRemoveChoice: (meal) => _removeChoice(c.$1, meal),
                onEditMeal: (meal) => _editMeal(c.$1, meal),
                onFitUploaded: (meal) => _fitUploaded(c.$1, meal),
              ),
          ],
          if (_panel == 2)
            _GroceryBlock(
              grocery: grocery,
              copied: _copied,
              onCopy: () => _copyGrocery(grocery),
            ),
          // Bottom of this page on purpose. Guideline 1.4.1 wants the
          // citations easy to find: the first two sources and the short
          // disclaimer are always visible, and the rest open in place.
          // Shown whenever there is a program — the targets are themselves
          // a health recommendation, with or without written guidelines.
          const SourceCitations(
            sources: kNutritionSources,
            disclaimer: kNutritionDisclaimer,
            initiallyVisible: 2,
          ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    required this.onPrevious,
    required this.onNext,
  });
  final String label;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onPrevious,
          icon: Icon(Icons.chevron_left, color: AppColors.txt),
        ),
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: AppColors.txt,
            ),
          ),
        ),
        IconButton(
          onPressed: onNext,
          icon: Icon(Icons.chevron_right, color: AppColors.txt),
        ),
      ],
    );
  }
}

class _TargetStrip extends StatelessWidget {
  const _TargetStrip({required this.targets});
  final Map<String, String?> targets;

  static const _fields = [
    ("calories", "CAL", false),
    ("protein", "PG", true),
    ("carbs", "CG", true),
    ("fats", "FG", true),
    ("water", "H2O", false),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key("nutrition-targets"),
      children: [
        for (var i = 0; i < _fields.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: _TargetTile(
                label: _fields[i].$2,
                value: _value(targets[_fields[i].$1], _fields[i].$3),
              ),
            ),
          ),
      ],
    );
  }

  static String _value(String? raw, bool percent) {
    final v = (raw ?? "").trim();
    if (v.isEmpty) return "—";
    return percent ? "$v%" : v;
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 18,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.txt,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9,
              color: AppColors.mute,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _GuidelinesCard extends StatelessWidget {
  const _GuidelinesCard({
    required this.text,
    required this.open,
    required this.onToggle,
  });
  final String text;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key("nutrition-guidelines"),
      onTap: onToggle,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "GUIDELINES",
            style: TextStyle(
              color: AppColors.mute,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          if (!open)
            Text(
              "Tap to read ⌄",
              style: TextStyle(
                fontSize: 13,
                color: AppColors.txt,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Text(
              text,
              style: TextStyle(fontSize: 13, color: AppColors.txt, height: 1.6),
            ),
        ],
      ),
    );
  }
}

class _GroceryBlock extends StatelessWidget {
  const _GroceryBlock({
    required this.grocery,
    required this.copied,
    required this.onCopy,
  });
  final List<IngredientGroceryItem> grocery;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    if (grocery.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          "Nothing on the list yet.",
          style: TextStyle(fontSize: 13, color: AppColors.mute),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SectionLabel("Grocery List"),
            OutlinedButton(
              onPressed: onCopy,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.gold,
                side: BorderSide(color: AppColors.line),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                copied ? "Copied!" : "Copy",
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: grocery
                .map(
                  (it) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            it.item,
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.txt,
                            ),
                          ),
                        ),
                        Text(
                          "${fmtQty(it.qty)}${it.unit != null ? ' ${it.unit}' : ''}",
                          style: TextStyle(fontSize: 13, color: AppColors.mute),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _CalorieBudgetPanel extends StatelessWidget {
  const _CalorieBudgetPanel({
    required this.mealBudgets,
    required this.dailyCalTarget,
  });
  final Map<String, String> mealBudgets;
  final int dailyCalTarget;

  static const _slots = [
    ("breakfast", "Breakfast"),
    ("lunch", "Lunch"),
    ("dinner", "Dinner"),
    ("snacks", "Snacks & Smoothies"),
  ];

  @override
  Widget build(BuildContext context) {
    // Smoothies have no box of their own. They still count in the total,
    // same as before.
    final allocated = [
      "breakfast",
      "lunch",
      "dinner",
      "snacks",
      "smoothies",
    ].fold<int>(0, (s, k) => s + (int.tryParse(mealBudgets[k] ?? "") ?? 0));
    final remaining = dailyCalTarget - allocated;
    final over = remaining < 0;
    final allGood = dailyCalTarget > 0 && !over && remaining.abs() < 10;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 16,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                "CALORIE BUDGET · REFERENCE ONLY",
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.gold,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final slot in _slots)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      slot.$2,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.15,
                        color: AppColors.mute,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final slot in _slots)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _BudgetValue(value: mealBudgets[slot.$1]),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                    children: [
                      const TextSpan(text: "Total: "),
                      TextSpan(
                        text: "$allocated kcal",
                        style: TextStyle(
                          color: AppColors.txt,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (dailyCalTarget > 0)
                Text(
                  allGood
                      ? "✓ On target"
                      : (over
                            ? "${remaining.abs()} kcal over"
                            : "$remaining kcal left"),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: allGood
                        ? AppColors.statusGreen
                        : (over ? AppColors.errorText : AppColors.gold),
                  ),
                ),
            ],
          ),
          if (dailyCalTarget > 0) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (allocated / dailyCalTarget).clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: AppColors.line,
                valueColor: AlwaysStoppedAnimation(
                  over ? AppColors.errorText : AppColors.gold,
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            "Daily target: ${dailyCalTarget > 0 ? '$dailyCalTarget kcal' : 'not set'}",
            style: TextStyle(fontSize: 12, color: AppColors.mute),
          ),
        ],
      ),
    );
  }
}

class _BudgetValue extends StatelessWidget {
  const _BudgetValue({this.value});
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        value ?? "—",
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: value != null ? AppColors.gold : AppColors.mute,
        ),
      ),
    );
  }
}

class _MealSection extends StatelessWidget {
  const _MealSection({
    required this.title,
    required this.meals,
    this.chosen = const [],
    this.budget,
    this.onChoose,
    this.onAddMeal,
    this.onRestaurant,
    this.onRemoveChoice,
    this.onEditMeal,
    this.onFitUploaded,
  });
  final String title;
  final List<NutritionMeal> meals;

  /// Meals the client picked themselves for this category.
  final List<NutritionMeal> chosen;

  /// The calorie budget for this meal, when the program set one — shown on
  /// the picker so a client can pick something that fits.
  final int? budget;
  final VoidCallback? onChoose;
  final VoidCallback? onAddMeal;
  final VoidCallback? onRestaurant;
  final ValueChanged<NutritionMeal>? onRemoveChoice;

  /// Opens the ingredient editor for one of the client's own picks. Null on
  /// the coach's suggested meals, which stay as prescribed.
  final ValueChanged<NutritionMeal>? onEditMeal;
  final ValueChanged<NutritionMeal>? onFitUploaded;

  @override
  Widget build(BuildContext context) {
    if (meals.isEmpty && chosen.isEmpty && onChoose == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SectionLabel(title)),
              if (onChoose != null)
                TextButton.icon(
                  onPressed: onChoose,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.gold,
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(Icons.add, size: 15),
                  label: Text(
                    budget != null ? "Choose (~$budget kcal)" : "Choose",
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          // The client's own picks first — they're what that person actually
          // plans to eat; the coach's suggestions stay below.
          ...chosen.map(
            (meal) => AppCard(
              borderColor: AppColors.gold,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          meal.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      Text(
                        meal.scale != null && (meal.scale! - 1).abs() > 0.02
                            ? "Fitted"
                            : "Your pick",
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.gold,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (onRemoveChoice != null)
                        IconButton(
                          tooltip: "Remove",
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onRemoveChoice!(meal),
                          icon: Icon(
                            Icons.close,
                            size: 16,
                            color: AppColors.mute,
                          ),
                        ),
                    ],
                  ),
                  // Recomputed from the ingredient quantities, so changing
                  // an amount moves these numbers straight away.
                  Builder(
                    builder: (context) {
                      final m = effectiveMacros(meal);
                      return Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _MacroChip(label: "Cal", value: "${m.calories}"),
                          _MacroChip(
                            label: "Pg",
                            value: "${m.protein.toInt()}",
                          ),
                          _MacroChip(label: "Cg", value: "${m.carbs.toInt()}"),
                          _MacroChip(label: "Fg", value: "${m.fats.toInt()}"),
                        ],
                      );
                    },
                  ),
                  ...effectiveIngredients(meal).map(
                    (ing) => Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              ing.item,
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.txt,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "${fmtQty(ing.qty)}${ing.unit != null ? ' ${ing.unit}' : ''}",
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.mute,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (onEditMeal != null)
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () => onEditMeal!(meal),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.gold,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            minimumSize: Size.zero,
                          ),
                          icon: const Icon(Icons.tune, size: 15),
                          label: Text(
                            meal.overrides.isEmpty
                                ? "Adjust ingredients"
                                : "Adjusted · edit again",
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(
                                text: ingredientListAsText(
                                  effectiveIngredients(meal),
                                ),
                              ),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("Ingredient list copied."),
                              ),
                            );
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.mute,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            minimumSize: Size.zero,
                          ),
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text(
                            "Copy ingredients",
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          ...meals.map(
            (meal) => AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          meal.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      if (meal.time != null)
                        Text(
                          meal.time!,
                          style: TextStyle(fontSize: 12, color: AppColors.gold),
                        ),
                    ],
                  ),
                  if (meal.calories > 0 || meal.protein > 0) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _MacroChip(label: "Cal", value: "${meal.calories}"),
                        _MacroChip(
                          label: "Pg",
                          value: "${meal.protein.toInt()}",
                        ),
                        _MacroChip(label: "Cg", value: "${meal.carbs.toInt()}"),
                        _MacroChip(label: "Fg", value: "${meal.fats.toInt()}"),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  ...meal.ingredients.map(
                    (ing) => Container(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: AppColors.line),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              ing.item,
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.txt,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "${fmtQty(ing.qty)}${ing.unit != null ? ' ${ing.unit}' : ''}",
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.mute,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (meal.notes != null && meal.notes!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        meal.notes!,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mute,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text: ingredientListAsText(meal.ingredients),
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Ingredient list copied."),
                            ),
                          );
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.mute,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                        ),
                        icon: const Icon(Icons.copy, size: 14),
                        label: const Text(
                          "Copy ingredients",
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (onFitUploaded != null)
                        TextButton(
                          onPressed: () => onFitUploaded!(meal),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.gold,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            minimumSize: Size.zero,
                          ),
                          child: const Text(
                            "Fit a serving to my budget",
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (onAddMeal != null || onRestaurant != null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onAddMeal != null)
                  OutlinedButton(
                    onPressed: onAddMeal,
                    child: const Text("Add a meal"),
                  ),
                if (onRestaurant != null)
                  OutlinedButton(
                    onPressed: onRestaurant,
                    child: Text("Restaurant for ${title.toLowerCase()}"),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MacroChip extends StatelessWidget {
  const _MacroChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 44),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.gold,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              color: AppColors.mute,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
