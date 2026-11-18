import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/food_catalog.dart";
import "../../../core/utils/meal_resize.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/meal_def.dart";
import "../../../data/models/nutrition_plan.dart";
import "../../../data/providers/trainer_providers.dart";
import "add_meal_screen.dart";

/// Lets a client pick their own meal for breakfast / lunch / dinner once
/// their program has calorie targets and per-meal budgets. Meals come from
/// the same catalogue coaches build programs from, so what a client picks
/// carries real ingredients and macros into their grocery list.
///
/// [budget] is that meal's calorie and macro budget. Choosing a meal copies
/// it and fits the portions to the budget. The library meal is not changed.
Future<NutritionMeal?> showClientMealPicker(
  BuildContext context,
  WidgetRef ref, {
  required String category,
  required String label,
  required SlotBudget budget,
}) {
  return showModalBottomSheet<NutritionMeal>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _ClientMealPickerBody(category: category, label: label, budget: budget),
    ),
  );
}

class _ClientMealPickerBody extends ConsumerStatefulWidget {
  const _ClientMealPickerBody({required this.category, required this.label, required this.budget});
  final String category;
  final String label;
  final SlotBudget budget;

  @override
  ConsumerState<_ClientMealPickerBody> createState() => _ClientMealPickerBodyState();
}

class _ClientMealPickerBodyState extends ConsumerState<_ClientMealPickerBody> {
  final _search = TextEditingController();
  String _diet = "";

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  NutritionMeal _toMeal(MealDef m) => mealFittedToBudget(m, widget.budget);

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final calorieBudget = widget.budget.calories;
    final all = [...ref.watch(mealCatalogProvider), ...ref.watch(customMealsProvider)]
        .where((m) => m.mealType == widget.category)
        .where((m) => mealMatchesDiet(m, _diet))
        .where((m) => q.isEmpty || m.name.toLowerCase().contains(q) || m.ingredients.any((i) => i.item.toLowerCase().contains(q)))
        .toList()
      ..sort((a, b) {
        if (calorieBudget == null) return a.name.compareTo(b.name);
        return (a.calories - calorieBudget).abs().compareTo((b.calories - calorieBudget).abs());
      });

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel("Choose your ${widget.label.toLowerCase()}"),
            Text(
              calorieBudget == null
                  ? "Search or filter, then pick a meal."
                  : "Portions are adjusted so the meal lands at or just under about $calorieBudget kcal.",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
            const SizedBox(height: 10),
            AppField(kind: FieldKind.search,
              controller: _search,
              placeholder: "Search meals or ingredients…",
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final tag in kClientDietFilters)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(tag.$2, style: TextStyle(fontSize: 11, color: _diet == tag.$1 ? AppColors.onGold : AppColors.mute)),
                        selected: _diet == tag.$1,
                        selectedColor: AppColors.gold,
                        backgroundColor: AppColors.bg,
                        side: BorderSide(color: _diet == tag.$1 ? AppColors.gold : AppColors.line),
                        onSelected: (_) => setState(() => _diet = tag.$1),
                      ),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  final created = await Navigator.of(context).push<MealDef>(
                    MaterialPageRoute(builder: (_) => AddMealScreen(mealType: widget.category, label: widget.label)),
                  );
                  if (created == null || !context.mounted) return;
                  Navigator.of(context).pop(mealFittedToBudget(created, widget.budget));
                },
                child: Text("Add a meal", style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: all.isEmpty
                  ? const HintBox(text: "No meals match. Try another search or diet, or add your own meal.")
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: all.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final m = all[i];
                        return AppCard(
                          margin: EdgeInsets.zero,
                          onTap: () => Navigator.of(context).pop(_toMeal(m)),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(m.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 2),
                                    Text(
                                      "${m.calories} kcal · P ${m.protein.toInt()} · C ${m.carbs.toInt()} · F ${m.fats.toInt()}",
                                      style: TextStyle(fontSize: 11.5, color: AppColors.mute),
                                    ),
                                    if (calorieBudget != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text("Portions fit your budget", style: TextStyle(fontSize: 11, color: AppColors.gold, fontWeight: FontWeight.w700)),
                                      ),
                                  ],
                                ),
                              ),
                              Icon(LucideIcons.chevronRight, size: 16, color: AppColors.mute),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
