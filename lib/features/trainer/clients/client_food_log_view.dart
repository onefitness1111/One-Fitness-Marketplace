import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/nutrition/food_log_view.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/nutrition_helpers.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/food_log.dart";
import "../../../data/models/nutrition_plan.dart";
import "../../../data/providers/trainer_providers.dart";

/// Read-only food log for one client. Coaches open it from a client they
/// already have; the owner opens it for anyone. Nothing here can be edited.
class ClientFoodLogView extends ConsumerWidget {
  const ClientFoodLogView({super.key, required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(trainerClientRecordsProvider)[clientId];
    return FoodLogDayPage(log: record?.foodLog ?? const FoodLog(), nutrition: record?.nutrition);
  }
}

class FoodLogDayPage extends StatefulWidget {
  const FoodLogDayPage({super.key, required this.log, this.nutrition, this.initialDay});

  final FoodLog log;
  final NutritionPlan? nutrition;
  final DateTime? initialDay;

  @override
  State<FoodLogDayPage> createState() => _FoodLogDayPageState();
}

class _FoodLogDayPageState extends State<FoodLogDayPage> {
  late DateTime _day = _dateOnly(widget.initialDay ?? DateTime.now());

  @override
  Widget build(BuildContext context) {
    final summary = foodLogDaySummary(log: widget.log, date: foodLogDate(_day), nutrition: widget.nutrition);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
              icon: Icon(Icons.chevron_left, color: AppColors.txt),
            ),
            Expanded(
              child: Text(
                _dayLabel(_day),
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.txt),
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _day = _day.add(const Duration(days: 1))),
              icon: Icon(Icons.chevron_right, color: AppColors.txt),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Totals(summary: summary),
        const SizedBox(height: 12),
        if (summary.isEmpty)
          const HintBox(text: "No food logged this day.")
        else
          for (final slot in summary.slots)
            if (slot.lines.isNotEmpty) _Slot(slot: slot),
      ],
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.summary});

  final FoodLogDaySummary summary;

  @override
  Widget build(BuildContext context) {
    final logged = summary.logged;
    final goal = summary.targets;
    final calories = goal == null ? "${logged.calories} kcal" : "${logged.calories} of ${goal.calories} kcal";
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(calories, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.txt)),
          const SizedBox(height: 4),
          Text(_macros(logged, goal), style: TextStyle(fontSize: 12.5, color: AppColors.mute, height: 1.4)),
        ],
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.slot});

  final FoodLogSlotLines slot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(slot.label, style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.txt)),
            for (final line in slot.lines) _Line(item: line),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.item});

  final FoodLogItem item;

  @override
  Widget build(BuildContext context) {
    final qty = "${fmtQty(item.qty)}${item.unit.isEmpty ? "" : " ${item.unit}"}";
    final estimated = foodLogEntryIsEstimated(item);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(item.name, style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.txt))),
              if (estimated)
                Text("Estimated", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.mute)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "$qty · ${item.calories} kcal · P ${fmtQty(item.protein)}g · C ${fmtQty(item.carbs)}g · F ${fmtQty(item.fats)}g",
            style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35),
          ),
        ],
      ),
    );
  }
}

String _macros(MacroSnapshot logged, FoodLogTargets? goal) {
  String side(String letter, double loggedGrams, double? target) {
    final got = "${fmtQty(loggedGrams)}g";
    if (target == null) return "$letter $got";
    return "$letter $got / ${fmtQty(target)}g";
  }

  return [
    side("P", logged.protein, goal?.protein),
    side("C", logged.carbs, goal?.carbs),
    side("F", logged.fats, goal?.fats),
  ].join(" · ");
}

DateTime _dateOnly(DateTime day) => DateTime(day.year, day.month, day.day);

const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const _months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

String _dayLabel(DateTime day) => "${_weekdays[day.weekday - 1]} ${_months[day.month - 1]} ${day.day}";
