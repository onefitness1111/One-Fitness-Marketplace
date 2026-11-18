import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/meal_resize.dart";
import "../../../core/utils/nutrition_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/food_log.dart";
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

/// Mirrors NutritionScreenReadOnly.jsx: training/rest macro targets, a
/// reference-only calorie budget panel, suggested meals per category, a
/// consolidated grocery list, and coach guidelines.
class NutritionTab extends ConsumerStatefulWidget {
  const NutritionTab({super.key});

  @override
  ConsumerState<NutritionTab> createState() => _NutritionTabState();
}

class _NutritionTabState extends ConsumerState<NutritionTab> {
  String _dayType = "training";
  bool _copied = false;

  /// Saves the client's own picks for one category, and keeps the screen in
  /// step whether or not the write reaches the server.
  Future<void> _saveChoices(String category, List<NutritionMeal> meals) async {
    final id = ref.read(clientInfoProvider).id;
    final next = {...ref.read(clientRecordProvider).myMeals, category: meals};
    ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(myMeals: next));
    try {
      await SupabaseService.updateClientChosenMeals(id, next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save your meal — check your connection and try again.")),
        );
      }
    }
  }

  SlotBudget _slotBudget(String category) {
    final n = ref.read(clientRecordProvider).nutrition;
    if (n == null) return const SlotBudget();
    final targets = _dayType == "training" ? n.trainingTargets : n.restTargets;
    final budgets = _dayType == "training" ? n.mealBudgets.training : n.mealBudgets.rest;
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
    final current = ref.read(clientRecordProvider).myMeals[category] ?? const <NutritionMeal>[];
    if (current.any((m) => m.id == picked.id)) return;
    await _saveChoices(category, [...current, picked]);
  }

  Future<void> _addOwnMeal(String category, String label) async {
    final created = await Navigator.of(context).push<MealDef>(
      MaterialPageRoute(builder: (_) => AddMealScreen(mealType: category, label: label)),
    );
    if (created == null) return;
    final fitted = mealFittedToBudget(created, _slotBudget(category));
    final current = ref.read(clientRecordProvider).myMeals[category] ?? const <NutritionMeal>[];
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
    final current = ref.read(clientRecordProvider).myMeals[category] ?? const <NutritionMeal>[];
    await _saveChoices(category, [...current, fitted]);
  }

  Future<void> _restaurant(String category, String label) async {
    final item = await showRestaurantSheet(context, slot: category, label: label, budget: _slotBudget(category));
    if (item == null) return;
    final id = ref.read(clientInfoProvider).id;
    final today = foodLogDate(DateTime.now());
    final next = ref.read(clientRecordProvider).foodLog.add(today, category, item);
    ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(foodLog: next));
    try {
      await SupabaseService.updateClientFoodLog(id, next);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save that. Try again.")));
    }
  }

  /// Lets the client change how much of each ingredient is in a meal they
  /// picked. Saved as per-ingredient overrides, so the original recipe is
  /// never overwritten and the totals recompute from the new amounts.
  Future<void> _editMeal(String category, NutritionMeal meal) async {
    final n = ref.read(clientRecordProvider).nutrition;
    final budget = int.tryParse(
      ((_dayType == "training" ? n?.mealBudgets.training : n?.mealBudgets.rest) ?? const {})[category] ?? "",
    );
    final updated = await showMealIngredientEditor(context, meal: meal, budget: budget);
    if (updated == null) return;
    final current = ref.read(clientRecordProvider).myMeals[category] ?? const <NutritionMeal>[];
    await _saveChoices(
      category,
      current.map((m) => m.id == updated.id ? updated : m).toList(),
    );
  }

  Future<void> _removeChoice(String category, NutritionMeal meal) async {
    final current = ref.read(clientRecordProvider).myMeals[category] ?? const <NutritionMeal>[];
    await _saveChoices(category, current.where((m) => m.id != meal.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientRecordProvider);
    final n = client.nutrition;

    if (n == null) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          FoodLogSection(dayType: _dayType),
          for (final c in const [("breakfast", "Breakfast"), ("lunch", "Lunch"), ("dinner", "Dinner")])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                onPressed: () => _restaurant(c.$1, c.$2),
                child: Text("Restaurant for ${c.$2.toLowerCase()}"),
              ),
            ),
          const HintBox(text: "Complete your Nutritional Assessment (under Forms) so your coach can build your nutrition program. It'll show up here. You can still log food above."),
        ],
      );
    }

    final targets = _dayType == "training" ? n.trainingTargets.asMap() : n.restTargets.asMap();
    final hasTargets = targets.values.any((v) => v != null && v.isNotEmpty);
    final dailyCal = int.tryParse(targets["calories"] ?? "") ?? 0;

    // The grocery list covers what the client actually plans to eat, so
    // their own picks belong in it as much as the coach's suggestions.
    final allMeals = [
      ...n.breakfast, ...n.lunch, ...n.dinner, ...n.snacks, ...n.smoothies,
      ...client.myMeals.values.expand((m) => m),
    ];
    final grocery = buildGroceryList(allMeals);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasTargets) ...[
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: AppColors.card,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  _DayTypeButton(label: "Training Day", selected: _dayType == "training", onTap: () => setState(() => _dayType = "training")),
                  _DayTypeButton(label: "Rest Day", selected: _dayType == "rest", onTap: () => setState(() => _dayType = "rest")),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SectionLabel("${_dayType == 'training' ? 'Training' : 'Rest'} Day Targets"),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kMacroFields.where((f) => targets[f.$1] != null && targets[f.$1]!.isNotEmpty).map((f) {
                final (key, _, unit) = f;
                return Container(
                  width: (MediaQuery.of(context).size.width - 18 * 2 - 8 * 2) / 3,
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Text(
                        "${targets[key]}${unit == '%' ? '%' : ''}",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.gold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        macroShortLabel(key).toUpperCase(),
                        style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 0.5),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            _CalorieBudgetPanel(mealBudgets: _dayType == "training" ? n.mealBudgets.training : n.mealBudgets.rest, dailyCalTarget: dailyCal),
            const SizedBox(height: 18),
          ],
          FoodLogSection(dayType: _dayType),

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
              budget: int.tryParse(
                (_dayType == "training" ? n.mealBudgets.training : n.mealBudgets.rest)[c.$1] ?? "",
              ),
              onChoose: () => _pickMeal(c.$1, c.$2),
              onAddMeal: () => _addOwnMeal(c.$1, c.$2),
              onRestaurant: c.$1 == "breakfast" || c.$1 == "lunch" || c.$1 == "dinner"
                  ? () => _restaurant(c.$1, c.$2)
                  : null,
              onRemoveChoice: (meal) => _removeChoice(c.$1, meal),
              onEditMeal: (meal) => _editMeal(c.$1, meal),
              onFitUploaded: (meal) => _fitUploaded(c.$1, meal),
            ),

          if (grocery.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SectionLabel("Grocery List"),
                OutlinedButton(
                  onPressed: () {
                    final text = grocery
                        .map((it) => "- ${it.item}${it.qty != null ? " (${fmtQty(it.qty)}${it.unit != null ? ' ${it.unit}' : ''})" : ""}")
                        .join("\n");
                    Clipboard.setData(ClipboardData(text: text));
                    setState(() => _copied = true);
                    Future.delayed(const Duration(milliseconds: 1500), () {
                      if (mounted) setState(() => _copied = false);
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.gold,
                    side: BorderSide(color: AppColors.line),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(_copied ? "Copied!" : "Copy", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: grocery
                    .map((it) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(it.item, style: TextStyle(fontSize: 13, color: AppColors.txt)),
                              Text(
                                "${fmtQty(it.qty)}${it.unit != null ? ' ${it.unit}' : ''}",
                                style: TextStyle(fontSize: 13, color: AppColors.mute),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
          ],

          if (n.guidelines != null && n.guidelines!.isNotEmpty) ...[
            const SectionLabel("Guidelines"),
            AppCard(
              child: Text(n.guidelines!, style: TextStyle(fontSize: 13, color: AppColors.txt, height: 1.6)),
            ),
          ],

          // Directly beneath the guidance, never folded away: App Review
          // guideline 1.4.1 requires health recommendations to carry
          // citations that are easy for the user to find. Shown whenever
          // there is a program at all — the targets above are themselves a
          // health recommendation, with or without written guidelines.
          const SourceCitations(
            sources: kNutritionSources,
            disclaimer: kNutritionDisclaimer,
          ),
        ],
      ),
    );
  }
}

class _DayTypeButton extends StatelessWidget {
  const _DayTypeButton({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.gold : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? AppColors.onGold : AppColors.mute),
          ),
        ),
      ),
    );
  }
}

class _CalorieBudgetPanel extends StatelessWidget {
  const _CalorieBudgetPanel({required this.mealBudgets, required this.dailyCalTarget});
  final Map<String, String> mealBudgets;
  final int dailyCalTarget;

  @override
  Widget build(BuildContext context) {
    final allocated = ["breakfast", "lunch", "dinner", "snacks", "smoothies"]
        .fold<int>(0, (s, k) => s + (int.tryParse(mealBudgets[k] ?? "") ?? 0));
    final remaining = dailyCalTarget - allocated;
    final over = remaining < 0;
    final allGood = dailyCalTarget > 0 && !over && remaining.abs() < 10;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "CALORIE BUDGET · REFERENCE ONLY",
            style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w700, letterSpacing: 1),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 520;
              final boxes = [
                _BudgetBox(label: "Breakfast", value: mealBudgets["breakfast"], stacked: stacked),
                _BudgetBox(label: "Lunch", value: mealBudgets["lunch"], stacked: stacked),
                _BudgetBox(label: "Dinner", value: mealBudgets["dinner"], stacked: stacked),
                _BudgetBox(label: "Snacks & Smoothies", value: mealBudgets["snacks"], stacked: stacked),
              ];
              // Four meal names at a readable size do not fit on one row of
              // a phone. Stack them. A wide screen can keep the row.
              if (stacked) {
                return Column(
                  children: [
                    for (final box in boxes) Padding(padding: const EdgeInsets.only(bottom: 6), child: box),
                  ],
                );
              }
              return Row(children: boxes);
            },
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 12, color: AppColors.mute),
                  children: [
                    const TextSpan(text: "Total: "),
                    TextSpan(text: "$allocated kcal", style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              if (dailyCalTarget > 0)
                Text(
                  allGood ? "✓ On target" : (over ? "${remaining.abs()} kcal over" : "$remaining kcal left"),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: allGood ? AppColors.statusGreen : (over ? AppColors.errorText : AppColors.gold),
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
                valueColor: AlwaysStoppedAnimation(over ? AppColors.errorText : AppColors.gold),
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

class _BudgetBox extends StatelessWidget {
  const _BudgetBox({required this.label, this.value, required this.stacked});
  final String label;
  final String? value;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final narrow = stacked;
    final labelStyle = TextStyle(fontSize: 13, color: AppColors.mute, fontWeight: FontWeight.w600);
    final chip = Container(
      width: narrow ? 88 : double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        value ?? "—",
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: value != null ? AppColors.gold : AppColors.mute),
      ),
    );
    if (narrow) {
      return Row(
        children: [
          Expanded(child: Text(label, style: labelStyle)),
          chip,
        ],
      );
    }
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          children: [
            Text(label, textAlign: TextAlign.center, style: labelStyle),
            const SizedBox(height: 3),
            chip,
          ],
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
    if (meals.isEmpty && chosen.isEmpty && onChoose == null) return const SizedBox.shrink();
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
                  style: TextButton.styleFrom(foregroundColor: AppColors.gold, padding: EdgeInsets.zero),
                  icon: const Icon(Icons.add, size: 15),
                  label: Text(
                    budget != null ? "Choose (~$budget kcal)" : "Choose",
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
          // The client's own picks first — they're what that person actually
          // plans to eat; the coach's suggestions stay below.
          ...chosen.map((meal) => AppCard(
                borderColor: AppColors.gold,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(meal.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                        Text(
                          meal.scale != null && (meal.scale! - 1).abs() > 0.02 ? "Fitted" : "Your pick",
                          style: TextStyle(fontSize: 10, color: AppColors.gold, fontWeight: FontWeight.w700),
                        ),
                        if (onRemoveChoice != null)
                          IconButton(
                            tooltip: "Remove",
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onRemoveChoice!(meal),
                            icon: Icon(Icons.close, size: 16, color: AppColors.mute),
                          ),
                      ],
                    ),
                    // Recomputed from the ingredient quantities, so changing
                    // an amount moves these numbers straight away.
                    Builder(builder: (context) {
                      final m = effectiveMacros(meal);
                      return Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _MacroChip(label: "Cal", value: "${m.calories}"),
                          _MacroChip(label: "Pg", value: "${m.protein.toInt()}"),
                          _MacroChip(label: "Cg", value: "${m.carbs.toInt()}"),
                          _MacroChip(label: "Fg", value: "${m.fats.toInt()}"),
                        ],
                      );
                    }),
                    ...effectiveIngredients(meal).map((ing) => Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(ing.item, style: TextStyle(fontSize: 13, color: AppColors.txt)),
                              Text(
                                "${fmtQty(ing.qty)}${ing.unit != null ? ' ${ing.unit}' : ''}",
                                style: TextStyle(fontSize: 13, color: AppColors.mute),
                              ),
                            ],
                          ),
                        )),
                    if (onEditMeal != null)
                      Wrap(
                        spacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: () => onEditMeal!(meal),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.gold,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                              minimumSize: Size.zero,
                            ),
                            icon: const Icon(Icons.tune, size: 15),
                            label: Text(
                              meal.overrides.isEmpty ? "Adjust ingredients" : "Adjusted · edit again",
                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: ingredientListAsText(effectiveIngredients(meal))));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ingredient list copied.")));
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.mute,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                              minimumSize: Size.zero,
                            ),
                            icon: const Icon(Icons.copy, size: 14),
                            label: const Text("Copy ingredients", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                  ],
                ),
              )),
          ...meals.map((meal) => AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(meal.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                        if (meal.time != null) Text(meal.time!, style: TextStyle(fontSize: 12, color: AppColors.gold)),
                      ],
                    ),
                    if (meal.calories > 0 || meal.protein > 0) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _MacroChip(label: "Cal", value: "${meal.calories}"),
                          _MacroChip(label: "Pg", value: "${meal.protein.toInt()}"),
                          _MacroChip(label: "Cg", value: "${meal.carbs.toInt()}"),
                          _MacroChip(label: "Fg", value: "${meal.fats.toInt()}"),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                    ...meal.ingredients.map((ing) => Container(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: AppColors.line)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(ing.item, style: TextStyle(fontSize: 13, color: AppColors.txt)),
                              Text(
                                "${fmtQty(ing.qty)}${ing.unit != null ? ' ${ing.unit}' : ''}",
                                style: TextStyle(fontSize: 13, color: AppColors.mute),
                              ),
                            ],
                          ),
                        )),
                    if (meal.notes != null && meal.notes!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(meal.notes!, style: TextStyle(fontSize: 12, color: AppColors.mute, fontStyle: FontStyle.italic)),
                      ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: ingredientListAsText(meal.ingredients)));
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ingredient list copied.")));
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.mute,
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                            minimumSize: Size.zero,
                          ),
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text("Copy ingredients", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                        ),
                        if (onFitUploaded != null)
                          TextButton(
                            onPressed: () => onFitUploaded!(meal),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.gold,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                              minimumSize: Size.zero,
                            ),
                            child: const Text("Fit a serving to my budget", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                  ],
                ),
              )),
          if (onAddMeal != null || onRestaurant != null)
            Wrap(
              spacing: 8,
              children: [
                if (onAddMeal != null)
                  OutlinedButton(onPressed: onAddMeal, child: const Text("Add a meal")),
                if (onRestaurant != null)
                  OutlinedButton(onPressed: onRestaurant, child: Text("Restaurant for ${title.toLowerCase()}")),
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
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(7)),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.gold)),
          Text(label, style: TextStyle(fontSize: 9, color: AppColors.mute, letterSpacing: 0.3)),
        ],
      ),
    );
  }
}
