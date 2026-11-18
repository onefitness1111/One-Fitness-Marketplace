import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/food_catalog.dart";
import "../../../core/utils/meal_resize.dart";
import "../../../core/utils/nutrition_helpers.dart";
import "../../../core/utils/photo_picker_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/food_log.dart";
import "../../../data/models/nutrition_plan.dart";
import "../../../data/providers/client_providers.dart";

/// The client's own food log for one day, next to the meal plan. Nothing
/// here changes a meal a coach or the owner uploaded.
class FoodLogSection extends ConsumerStatefulWidget {
  const FoodLogSection({super.key, required this.dayType});

  /// "training" or "rest" — which budget the totals are compared with.
  final String dayType;

  @override
  ConsumerState<FoodLogSection> createState() => _FoodLogSectionState();
}

class _FoodLogSectionState extends ConsumerState<FoodLogSection> {
  DateTime _day = DateTime.now();

  String get _date => foodLogDate(_day);

  SlotBudget _slotBudget(String slot) {
    final n = ref.read(clientRecordProvider).nutrition;
    if (n == null) return const SlotBudget();
    final targets = widget.dayType == "training" ? n.trainingTargets : n.restTargets;
    final budgets = widget.dayType == "training" ? n.mealBudgets.training : n.mealBudgets.rest;
    return SlotBudget.forSlot(
      slotCalories: int.tryParse(budgets[slot] ?? ""),
      proteinPct: targets.protein,
      carbsPct: targets.carbs,
      fatsPct: targets.fats,
    );
  }

  int get _dailyCalories {
    final n = ref.read(clientRecordProvider).nutrition;
    if (n == null) return 0;
    final targets = widget.dayType == "training" ? n.trainingTargets : n.restTargets;
    return int.tryParse(targets.calories ?? "") ?? 0;
  }

  Future<void> _save(FoodLog next) async {
    final id = ref.read(clientInfoProvider).id;
    ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(foodLog: next));
    try {
      await SupabaseService.updateClientFoodLog(id, next);
      try {
        final fresh = await SupabaseService.loadMeritBadgesFor(id);
        ref.read(earnedBadgesProvider.notifier).replaceForClient(id, fresh);
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      final text = e.toString().replaceFirst("Exception: ", "");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text.toLowerCase().contains("ai") ? "Couldn't save that. Try again." : text),
      ));
    }
  }

  Future<void> _add(String slot, FoodLogItem item) async {
    final log = ref.read(clientRecordProvider).foodLog;
    await _save(log.add(_date, slot, item));
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(clientRecordProvider).foodLog;
    final totals = log.totalsFor(_date);
    final daily = _dailyCalories;
    final over = daily > 0 && totals.calories > daily;
    final label = "${_day.month}/${_day.day}";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: SectionLabel("Food log")),
            IconButton(
              onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
              icon: Icon(Icons.chevron_left, color: AppColors.mute),
            ),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(
              onPressed: () => setState(() => _day = _day.add(const Duration(days: 1))),
              icon: Icon(Icons.chevron_right, color: AppColors.mute),
            ),
          ],
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                daily > 0 ? "${totals.calories} of $daily kcal" : "${totals.calories} kcal logged",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: over ? AppColors.danger : AppColors.txt),
              ),
              const SizedBox(height: 4),
              Text(
                "P ${fmtQty(totals.protein)}g · C ${fmtQty(totals.carbs)}g · F ${fmtQty(totals.fats)}g",
                style: TextStyle(fontSize: 12.5, color: AppColors.mute),
              ),
              if (daily > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (totals.calories / daily).clamp(0, 1).toDouble(),
                    minHeight: 4,
                    backgroundColor: AppColors.line,
                    color: over ? AppColors.danger : AppColors.gold,
                  ),
                ),
              ],
            ],
          ),
        ),
        for (final slot in const [
          ("breakfast", "Breakfast"),
          ("lunch", "Lunch"),
          ("dinner", "Dinner"),
          ("snacks", "Snacks"),
          ("smoothies", "Smoothies"),
        ])
          _SlotCard(
            label: slot.$2,
            lines: log.lines(_date, slot.$1),
            spent: log.totalsForSlot(_date, slot.$1),
            budget: _slotBudget(slot.$1),
            recents: log.recents,
            onAdd: (item) => _add(slot.$1, item),
            onRemove: (id) => _save(log.remove(_date, slot.$1, id)),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.label,
    required this.lines,
    required this.spent,
    required this.budget,
    required this.recents,
    required this.onAdd,
    required this.onRemove,
  });

  final String label;
  final List<FoodLogItem> lines;
  final MacroSnapshot spent;
  final SlotBudget budget;
  final List<FoodLogItem> recents;
  final ValueChanged<FoodLogItem> onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final cap = budget.calories;
    final over = cap != null && spent.calories > cap;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800))),
              Text(
                cap == null ? "${spent.calories} kcal" : "${spent.calories} / $cap kcal",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: over ? AppColors.danger : AppColors.mute),
              ),
            ],
          ),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Text("Nothing logged.", style: TextStyle(fontSize: 12, color: AppColors.mute)),
            ),
          ...lines.map((line) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(line.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                          Text(
                            "${fmtQty(line.qty)} ${line.unit} · ${line.calories} kcal · P ${fmtQty(line.protein)} C ${fmtQty(line.carbs)} F ${fmtQty(line.fats)}",
                            style: TextStyle(fontSize: 11.5, color: AppColors.mute),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => onRemove(line.id),
                      icon: Icon(Icons.close, size: 16, color: AppColors.mute),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _MiniButton(label: "Search", onTap: () => _search(context)),
              _MiniButton(label: "Quick add", onTap: () => _quickAdd(context)),
              _MiniButton(label: "Recents", onTap: () => _recents(context)),
              _MiniButton(label: "Snap a meal", onTap: () => _snap(context)),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _search(BuildContext context) async {
    final item = await showModalBottomSheet<FoodLogItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => const _FoodSearchSheet(),
    );
    if (item != null) onAdd(item);
  }

  Future<void> _quickAdd(BuildContext context) async {
    final item = await showModalBottomSheet<FoodLogItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: const _QuickAddSheet(),
      ),
    );
    if (item != null) onAdd(item);
  }

  Future<void> _recents(BuildContext context) async {
    if (recents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Foods you log will show up here.")));
      return;
    }
    final item = await showModalBottomSheet<FoodLogItem>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(18),
          children: [
            const SectionLabel("Recents"),
            ...recents.map((line) => AppCard(
                  onTap: () => Navigator.of(ctx).pop(line.copyWith(id: "log-${DateTime.now().microsecondsSinceEpoch}")),
                  child: Text("${line.name} · ${line.calories} kcal", style: const TextStyle(fontWeight: FontWeight.w600)),
                )),
          ],
        ),
      ),
    );
    if (item != null) onAdd(item);
  }

  Future<void> _snap(BuildContext context) async {
    final source = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text("Take a photo"), onTap: () => Navigator.pop(ctx, true)),
            ListTile(title: const Text("Choose a photo"), onTap: () => Navigator.pop(ctx, false)),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    final bytes = await pickPlatePhotoBytes(camera: source);
    if (bytes == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
    Map<String, dynamic> res;
    try {
      res = await SupabaseService.estimatePlate(base64Encode(bytes));
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_plain(e))));
      }
      return;
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (res["ok"] != true) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_plain(res["error"] ?? "Couldn't make an estimate."))));
      }
      return;
    }
    if (!context.mounted) return;
    final item = await showModalBottomSheet<FoodLogItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: _EstimateConfirm(estimate: res),
      ),
    );
    if (item != null) onAdd(item);
  }

  String _plain(Object e) {
    final text = e.toString().replaceFirst("Exception: ", "");
    if (text.toLowerCase().contains("ai")) return "Couldn't make an estimate. Try again.";
    return text;
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.txt,
        side: BorderSide(color: AppColors.line),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _FoodSearchSheet extends StatefulWidget {
  const _FoodSearchSheet();

  @override
  State<_FoodSearchSheet> createState() => _FoodSearchSheetState();
}

class _FoodSearchSheetState extends State<_FoodSearchSheet> {
  final _search = TextEditingController();
  FoodItem? _picked;
  final _qty = TextEditingController(text: "1");

  @override
  void dispose() {
    _search.dispose();
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hits = searchFoods(_search.text).take(12).toList();
    final qty = double.tryParse(_qty.text.trim()) ?? 0;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel("Search foods"),
                AppField(kind: FieldKind.search, controller: _search, placeholder: "Food name", onChanged: (_) => setState(() {})),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: hits
                        .map((food) => AppCard(
                              margin: const EdgeInsets.only(bottom: 8),
                              borderColor: _picked == food ? AppColors.gold : null,
                              onTap: () => setState(() => _picked = food),
                              child: Text(
                                "${food.name} · ${fmtQty(food.calories)} kcal per ${food.unit}",
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ))
                        .toList(),
                  ),
                ),
                if (_picked != null) ...[
                  Row(
                    children: [
                      SizedBox(width: 80, child: AppField(controller: _qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}))),
                      const SizedBox(width: 8),
                      Text(_picked!.unit, style: TextStyle(color: AppColors.mute)),
                      const Spacer(),
                      BtnGold(
                        onPressed: qty <= 0
                            ? null
                            : () => Navigator.pop(
                                  context,
                                  FoodLogItem(
                                    id: "log-${DateTime.now().microsecondsSinceEpoch}",
                                    name: _picked!.name,
                                    qty: qty,
                                    unit: _picked!.unit,
                                    calories: (_picked!.calories * qty).round(),
                                    protein: _picked!.protein * qty,
                                    carbs: _picked!.carbs * qty,
                                    fats: _picked!.fats * qty,
                                  ),
                                ),
                        child: const Text("Log"),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickAddSheet extends StatefulWidget {
  const _QuickAddSheet();

  @override
  State<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<_QuickAddSheet> {
  final _name = TextEditingController();
  final _cal = TextEditingController();
  final _p = TextEditingController();
  final _c = TextEditingController();
  final _f = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _cal.dispose();
    _p.dispose();
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel("Quick add"),
            AppField(kind: FieldKind.name, controller: _name, placeholder: "Name"),
            const SizedBox(height: 8),
            AppField(controller: _cal, placeholder: "Calories", keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: AppField(controller: _p, placeholder: "Protein g", keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 6),
                Expanded(child: AppField(controller: _c, placeholder: "Carbs g", keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 6),
                Expanded(child: AppField(controller: _f, placeholder: "Fat g", keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              ],
            ),
            const SizedBox(height: 12),
            BtnGold(
              full: true,
              onPressed: () {
                final name = _name.text.trim();
                final calories = int.tryParse(_cal.text.trim());
                if (name.isEmpty || calories == null) return;
                Navigator.pop(
                  context,
                  FoodLogItem(
                    id: "log-${DateTime.now().microsecondsSinceEpoch}",
                    name: name,
                    qty: 1,
                    unit: "serving",
                    calories: calories,
                    protein: double.tryParse(_p.text.trim()) ?? 0,
                    carbs: double.tryParse(_c.text.trim()) ?? 0,
                    fats: double.tryParse(_f.text.trim()) ?? 0,
                  ),
                );
              },
              child: const Text("Log"),
            ),
          ],
        ),
      ),
    );
  }
}

class _EstimateConfirm extends StatefulWidget {
  const _EstimateConfirm({required this.estimate});
  final Map<String, dynamic> estimate;

  @override
  State<_EstimateConfirm> createState() => _EstimateConfirmState();
}

class _EstimateConfirmState extends State<_EstimateConfirm> {
  late final _name = TextEditingController(text: widget.estimate["name"]?.toString() ?? "Plate");
  late final _cal = TextEditingController(text: "${widget.estimate["calories"] ?? 0}");
  late final _p = TextEditingController(text: "${widget.estimate["protein"] ?? 0}");
  late final _c = TextEditingController(text: "${widget.estimate["carbs"] ?? 0}");
  late final _f = TextEditingController(text: "${widget.estimate["fats"] ?? 0}");

  @override
  void dispose() {
    _name.dispose();
    _cal.dispose();
    _p.dispose();
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel("Estimate"),
            Text(
              "Check the numbers and change anything that looks off, then log it.",
              style: TextStyle(fontSize: 12.5, color: AppColors.mute, height: 1.35),
            ),
            const SizedBox(height: 10),
            AppField(kind: FieldKind.name, controller: _name, placeholder: "Name"),
            const SizedBox(height: 8),
            AppField(controller: _cal, placeholder: "Calories", keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: AppField(controller: _p, placeholder: "Protein g", keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 6),
                Expanded(child: AppField(controller: _c, placeholder: "Carbs g", keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 6),
                Expanded(child: AppField(controller: _f, placeholder: "Fat g", keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              ],
            ),
            const SizedBox(height: 12),
            BtnGold(
              full: true,
              onPressed: () {
                final calories = int.tryParse(_cal.text.trim());
                if (_name.text.trim().isEmpty || calories == null) return;
                Navigator.pop(
                  context,
                  FoodLogItem(
                    id: "snap-${DateTime.now().microsecondsSinceEpoch}",
                    name: _name.text.trim(),
                    qty: 1,
                    unit: "plate",
                    calories: calories,
                    protein: double.tryParse(_p.text.trim()) ?? 0,
                    carbs: double.tryParse(_c.text.trim()) ?? 0,
                    fats: double.tryParse(_f.text.trim()) ?? 0,
                  ),
                );
              },
              child: const Text("Log this estimate"),
            ),
          ],
        ),
      ),
    );
  }
}
