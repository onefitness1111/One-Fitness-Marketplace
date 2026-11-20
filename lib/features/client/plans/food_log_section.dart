import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/food_catalog.dart";
import "../../../core/utils/meal_resize.dart";
import "../../../core/utils/nutrition_helpers.dart";
import "../../../core/utils/photo_picker_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/food_log.dart";
import "../../../data/models/nutrition_plan.dart";
import "../../../data/models/meal_def.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "restaurant_sheet.dart";

/// The client's own food log for one day, next to the meal plan. Nothing
/// here changes a meal a coach or the owner uploaded.
class FoodLogSection extends ConsumerStatefulWidget {
  const FoodLogSection({super.key});

  @override
  ConsumerState<FoodLogSection> createState() => _FoodLogSectionState();
}

class _FoodLogSectionState extends ConsumerState<FoodLogSection> {
  DateTime _day = DateTime.now();
  String _dayType = "training";

  String get _date => foodLogDate(_day);

  SlotBudget _slotBudget(String slot) {
    final n = ref.read(clientRecordProvider).nutrition;
    if (n == null) return const SlotBudget();
    final targets = _dayType == "training" ? n.trainingTargets : n.restTargets;
    final budgets = _dayType == "training" ? n.mealBudgets.training : n.mealBudgets.rest;
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
    final targets = _dayType == "training" ? n.trainingTargets : n.restTargets;
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
    final record = ref.watch(clientRecordProvider);
    final log = record.foodLog;
    final totals = log.totalsFor(_date);
    final daily = _dailyCalories;
    final left = daily > 0 ? (daily - totals.calories) : null;
    final macros = _macroTargets();
    final label = "${_day.month}/${_day.day}";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
              icon: Icon(Icons.chevron_left, color: AppColors.txt),
            ),
            Expanded(
              child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.txt)),
            ),
            IconButton(
              onPressed: () => setState(() => _day = _day.add(const Duration(days: 1))),
              icon: Icon(Icons.chevron_right, color: AppColors.txt),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _DayChip(label: "Training", selected: _dayType == "training", onTap: () => setState(() => _dayType = "training")),
            const SizedBox(width: 8),
            _DayChip(label: "Rest", selected: _dayType == "rest", onTap: () => setState(() => _dayType = "rest")),
          ],
        ),
        const SizedBox(height: 16),
        Center(child: _CalorieRing(left: left, consumed: totals.calories, target: daily)),
        const SizedBox(height: 18),
        _MacroBar(label: "Protein", grams: totals.protein, target: macros.$1),
        _MacroBar(label: "Carbs", grams: totals.carbs, target: macros.$2),
        _MacroBar(label: "Fat", grams: totals.fats, target: macros.$3),
        const SizedBox(height: 8),
        for (final slot in const [
          ("breakfast", "Breakfast"),
          ("lunch", "Lunch"),
          ("dinner", "Dinner"),
          ("snacks", "Snacks"),
        ])
          _MealRow(
            label: slot.$2,
            lines: [
              ...log.lines(_date, slot.$1),
              if (slot.$1 == "snacks") ...log.lines(_date, "smoothies"),
            ],
            calories: log.totalsForSlot(_date, slot.$1).calories + (slot.$1 == "snacks" ? log.totalsForSlot(_date, "smoothies").calories : 0),
            onAdd: () => _openAdd(slot.$1, slot.$2),
            onRemove: (id) {
              final inSnacks = log.lines(_date, slot.$1).any((line) => line.id == id);
              final key = inSnacks ? slot.$1 : "smoothies";
              _save(log.remove(_date, key, id));
            },
          ),
      ],
    );
  }

  (double?, double?, double?) _macroTargets() {
    final n = ref.read(clientRecordProvider).nutrition;
    if (n == null) return (null, null, null);
    final targets = _dayType == "training" ? n.trainingTargets : n.restTargets;
    final calories = int.tryParse(targets.calories ?? "") ?? 0;
    if (calories <= 0) return (null, null, null);
    double? grams(String? pct, double per) {
      final p = double.tryParse((pct ?? "").trim());
      if (p == null || p <= 0) return null;
      return calories * (p / 100) / per;
    }

    return (grams(targets.protein, 4), grams(targets.carbs, 4), grams(targets.fats, 9));
  }

  Future<void> _openAdd(String slot, String label) async {
    final record = ref.read(clientRecordProvider);
    final n = record.nutrition;
    final saved = <NutritionMeal>[
      if (n != null) ..._uploaded(n, slot),
      ...record.myMeals[slot] ?? const <NutritionMeal>[],
      if (slot == "snacks") ...[
        if (n != null) ...n.smoothies,
        ...record.myMeals["smoothies"] ?? const <NutritionMeal>[],
      ],
    ];
    final item = await showModalBottomSheet<FoodLogItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => AddFoodSheet(
        mealLabel: label,
        mealSlot: slot == "smoothies" ? "snacks" : slot,
        recents: record.foodLog.recents,
        savedMeals: saved,
        onSnap: () => _snap(ctx),
        onRestaurant: () => showRestaurantSheet(ctx, slot: slot, label: label, budget: _slotBudget(slot)),
      ),
    );
    if (item != null) await _add(slot, item);
  }

  List<NutritionMeal> _uploaded(NutritionPlan n, String slot) => switch (slot) {
        "breakfast" => n.breakfast,
        "lunch" => n.lunch,
        "dinner" => n.dinner,
        "snacks" => n.snacks,
        _ => n.smoothies,
      };

  Future<FoodLogItem?> _snap(BuildContext context) async {
    final source = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text("Take a pic"), onTap: () => Navigator.pop(ctx, true)),
            ListTile(title: const Text("Choose a photo"), onTap: () => Navigator.pop(ctx, false)),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return null;
    final bytes = await pickPlatePhotoBytes(camera: source);
    if (bytes == null || !context.mounted) return null;
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
      return null;
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (res["ok"] != true) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_plain(res["error"] ?? "Couldn't make an estimate."))));
      }
      return null;
    }
    if (!context.mounted) return null;
    return showModalBottomSheet<FoodLogItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: _EstimateConfirm(estimate: res),
      ),
    );
  }

  String _plain(Object e) {
    final text = e.toString().replaceFirst("Exception: ", "");
    if (text.toLowerCase().contains("ai")) return "Couldn't make an estimate. Try again.";
    return text;
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.txt : AppColors.bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.txt : AppColors.line),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? AppColors.bg : AppColors.mute)),
      ),
    );
  }
}

class _CalorieRing extends StatelessWidget {
  const _CalorieRing({required this.left, required this.consumed, required this.target});
  final int? left;
  final int consumed;
  final int target;

  @override
  Widget build(BuildContext context) {
    final progress = target <= 0 ? 0.0 : (consumed / target).clamp(0.0, 1.0);
    final number = left == null ? _commas(consumed) : _commas(left! < 0 ? 0 : left!);
    final caption = left == null ? "logged" : "left";
    return SizedBox(
      width: 168,
      height: 168,
      child: CustomPaint(
        painter: _RingPainter(progress: progress),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(number, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.txt)),
            Text(caption, style: TextStyle(fontSize: 13, color: AppColors.mute)),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    final track = Paint()
      ..color = AppColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;
    final arc = Paint()
      ..color = AppColors.txt
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -1.5708, 6.28318 * progress, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

class _MacroBar extends StatelessWidget {
  const _MacroBar({required this.label, required this.grams, required this.target});
  final String label;
  final double grams;
  final double? target;

  @override
  Widget build(BuildContext context) {
    final fraction = target == null || target! <= 0 ? (grams > 0 ? 1.0 : 0.0) : (grams / target!).clamp(0.0, 1.0);
    final detail = target == null ? "${fmtQty(grams)}g" : "${fmtQty(grams)} / ${fmtQty(target)}g";
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.txt))),
              Text(detail, style: TextStyle(fontSize: 12, color: AppColors.mute)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: AppColors.line,
              color: AppColors.txt,
            ),
          ),
        ],
      ),
    );
  }
}

class _MealRow extends StatelessWidget {
  const _MealRow({required this.label, required this.lines, required this.calories, required this.onAdd, required this.onRemove});
  final String label;
  final List<FoodLogItem> lines;
  final int calories;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.txt)),
                if (lines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text("Nothing logged", style: TextStyle(fontSize: 12, color: AppColors.mute)),
                  )
                else
                  ...lines.map((line) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                "${line.name} · ${line.calories} kcal${foodLogEntryIsEstimated(line) ? " · Estimated" : ""}",
                                style: TextStyle(fontSize: 13, color: AppColors.txt),
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
                if (lines.isNotEmpty)
                  Text("$calories kcal", style: TextStyle(fontSize: 12, color: AppColors.mute)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: InkWell(
              onTap: onAdd,
              customBorder: const CircleBorder(),
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.txt)),
                child: Icon(Icons.add, size: 18, color: AppColors.txt),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool foodLogEntryIsEstimated(FoodLogItem item) => item.id.startsWith("snap-") || item.unit.trim().toLowerCase() == "plate";

String _commas(int n) {
  final raw = n.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    if (i > 0 && (raw.length - i) % 3 == 0) out.write(",");
    out.write(raw[i]);
  }
  return n < 0 ? "-$out" : out.toString();
}

/// Bottom sheet opened from a meal's + button. Search, quick add, saved
/// meals, a photo, and restaurants all live here instead of on the page.
class AddFoodSheet extends ConsumerStatefulWidget {
  const AddFoodSheet({
    super.key,
    required this.mealLabel,
    required this.mealSlot,
    required this.recents,
    required this.savedMeals,
    required this.onSnap,
    required this.onRestaurant,
  });

  final String mealLabel;

  /// breakfast, lunch, dinner, or snacks. The search filter starts here.
  final String mealSlot;
  final List<FoodLogItem> recents;
  final List<NutritionMeal> savedMeals;
  final Future<FoodLogItem?> Function() onSnap;
  final Future<FoodLogItem?> Function() onRestaurant;

  @override
  ConsumerState<AddFoodSheet> createState() => _AddFoodSheetState();
}

class _AddFoodSheetState extends ConsumerState<AddFoodSheet> {
  int _tab = 0;
  final _seen = <int>{};

  static const _tabs = ["Your meals", "Search", "Take a pic", "Restaurant", "Quick add"];
  static const _tipKeys = ["your-meals", "search", "take-a-pic", "restaurant", "quick-add"];
  static const _tips = [
    "Foods you have logged and meals saved on your program. Tap one to add it to this meal.",
    "Search foods and meals. Filter by a diet, or by breakfast, lunch, dinner, or snacks.",
    "Take a picture of your plate. You can correct the estimate, and the log labels it Estimated.",
    "Look up a restaurant and log something from the menu. The numbers are an estimate.",
    "Type a name and the calories yourself when the food is not in the list.",
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tip(0));
  }

  Future<void> _tip(int index) async {
    if (_seen.contains(index)) return;
    final prefs = await SharedPreferences.getInstance();
    final user = ref.read(clientInfoProvider).id;
    final key = "food_tab_tip:${user.isEmpty ? "local" : user}:${_tipKeys[index]}";
    if (prefs.getBool(key) == true) {
      _seen.add(index);
      return;
    }
    if (!mounted || _tab != index) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(_tabs[index], style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w800)),
        content: Text(_tips[index], style: TextStyle(color: AppColors.txt, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Dismiss", style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    _seen.add(index);
    await prefs.setBool(key, true);
  }

  void _select(int index) {
    setState(() => _tab = index);
    _tip(index);
  }

  Future<void> _finish(Future<FoodLogItem?> Function() load) async {
    final item = await load();
    if (item != null && mounted) Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      child: SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Text("Add to ${widget.mealLabel}", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.txt)),
            ),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(_tabs[i]),
                        selected: _tab == i,
                        onSelected: (_) => _select(i),
                        selectedColor: AppColors.txt,
                        backgroundColor: AppColors.bg,
                        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _tab == i ? AppColors.bg : AppColors.txt),
                        side: BorderSide(color: _tab == i ? AppColors.txt : AppColors.line),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _body()),
          ],
        ),
      ),
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case 1:
        final meals = [...ref.watch(mealCatalogProvider), ...ref.watch(customMealsProvider)];
        return _FoodSearchSheet(initialMeal: widget.mealSlot, meals: meals);
      case 2:
        return _TakePicTab(onPressed: () => _finish(widget.onSnap));
      case 3:
        return _TakePicTab(label: "Find a restaurant", onPressed: () => _finish(widget.onRestaurant));
      case 4:
        return const _QuickAddSheet();
      default:
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text("Recents", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.mute)),
            if (widget.recents.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 12),
                child: Text("Foods you log will show up here.", style: TextStyle(fontSize: 13, color: AppColors.mute)),
              )
            else
              ...widget.recents.map((line) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(line.name, style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
                    subtitle: Text("${line.calories} kcal", style: TextStyle(color: AppColors.mute)),
                    onTap: () => Navigator.pop(context, line.copyWith(id: "log-${DateTime.now().microsecondsSinceEpoch}")),
                  )),
            const SizedBox(height: 8),
            Text("Saved", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.mute)),
            if (widget.savedMeals.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text("Meals from your program show up here.", style: TextStyle(fontSize: 13, color: AppColors.mute)),
              )
            else
              ...widget.savedMeals.map((meal) {
                final macros = effectiveMacros(meal);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(meal.name, style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
                  subtitle: Text("${macros.calories} kcal", style: TextStyle(color: AppColors.mute)),
                  onTap: () => Navigator.pop(
                    context,
                    FoodLogItem(
                      id: "log-${DateTime.now().microsecondsSinceEpoch}",
                      name: meal.name,
                      qty: 1,
                      unit: "serving",
                      calories: macros.calories,
                      protein: macros.protein,
                      carbs: macros.carbs,
                      fats: macros.fats,
                    ),
                  ),
                );
              }),
          ],
        );
    }
  }
}

class _TakePicTab extends StatelessWidget {
  const _TakePicTab({required this.onPressed, this.label = "Take a pic"});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label == "Take a pic" ? "Photograph the plate. The estimate is labeled Estimated after you log it." : "Search a restaurant and log an estimate.",
            style: TextStyle(fontSize: 13, color: AppColors.mute, height: 1.4),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.txt, side: BorderSide(color: AppColors.txt)),
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
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
  const _FoodSearchSheet({required this.initialMeal, required this.meals});

  /// The meal the sheet was opened from: breakfast, lunch, dinner, or snacks.
  final String initialMeal;
  final List<MealDef> meals;

  @override
  State<_FoodSearchSheet> createState() => _FoodSearchSheetState();
}

class _FoodSearchSheetState extends State<_FoodSearchSheet> {
  final _search = TextEditingController();
  FoodItem? _picked;
  final _qty = TextEditingController(text: "1");
  late String _meal = widget.initialMeal;
  String _diet = "";

  static const _meals = [("all", "All"), ("breakfast", "Breakfast"), ("lunch", "Lunch"), ("dinner", "Dinner"), ("snacks", "Snacks")];
  static const _diets = [("", "Any diet"), ("vegetarian", "Vegetarian"), ("vegan", "Vegan"), ("gluten-free", "Gluten-free"), ("dairy-free", "Dairy-free"), ("keto", "Keto")];

  @override
  void dispose() {
    _search.dispose();
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hits = searchFoods(_search.text).where((food) => foodMatchesMeal(food, _meal) && foodMatchesDiet(food, _diet)).take(12).toList();
    final mealHits = widget.meals.where((meal) {
      final q = _search.text.trim().toLowerCase();
      if (q.isNotEmpty && !meal.name.toLowerCase().contains(q)) return false;
      return mealMatchesSlot(meal, _meal) && mealMatchesDiet(meal, _diet);
    }).take(12).toList();
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
                const SectionLabel("Search"),
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final meal in _meals)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(meal.$2),
                            selected: _meal == meal.$1,
                            onSelected: (_) => setState(() => _meal = meal.$1),
                            selectedColor: AppColors.txt,
                            backgroundColor: AppColors.bg,
                            labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _meal == meal.$1 ? AppColors.bg : AppColors.txt),
                            side: BorderSide(color: AppColors.line),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final diet in _diets)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(diet.$2),
                            selected: _diet == diet.$1,
                            onSelected: (_) => setState(() => _diet = diet.$1),
                            selectedColor: AppColors.txt,
                            backgroundColor: AppColors.bg,
                            labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _diet == diet.$1 ? AppColors.bg : AppColors.txt),
                            side: BorderSide(color: AppColors.line),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                AppField(kind: FieldKind.search, controller: _search, placeholder: "Food name", onChanged: (_) => setState(() {})),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      ...mealHits.map((meal) => AppCard(
                            margin: const EdgeInsets.only(bottom: 8),
                            onTap: () => Navigator.pop(
                              context,
                              FoodLogItem(
                                id: "log-${DateTime.now().microsecondsSinceEpoch}",
                                name: meal.name,
                                qty: 1,
                                unit: "serving",
                                calories: meal.calories,
                                protein: meal.protein,
                                carbs: meal.carbs,
                                fats: meal.fats,
                              ),
                            ),
                            child: Text("${meal.name} · ${meal.calories} kcal", style: const TextStyle(fontWeight: FontWeight.w600)),
                          )),
                      ...hits
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
                    ],
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
