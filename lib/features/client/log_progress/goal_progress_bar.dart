import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/progress_summary.dart";
import "../../../core/widgets/app_card.dart";
import "../../../data/models/progress_goal.dart";
import "../../../data/providers/client_providers.dart";

/// One goal — weight, inches, or a lift — on the Log Progress screen.
class GoalProgressBar extends ConsumerStatefulWidget {
  const GoalProgressBar({super.key});

  @override
  ConsumerState<GoalProgressBar> createState() => _GoalProgressBarState();
}

class _GoalProgressBarState extends ConsumerState<GoalProgressBar> {
  bool _saving = false;

  Future<void> _edit(ProgressGoal? current) async {
    final record = ref.read(clientRecordProvider);
    final liftNames = <String>{
      for (final log in record.workoutLogs)
        for (final ex in log.exercises) ex.name,
    }.toList()
      ..sort();
    final draft = await showDialog<ProgressGoal?>(
      context: context,
      builder: (ctx) => _GoalDialog(current: current, lifts: liftNames),
    );
    if (draft == null && current == null) return;
    if (!mounted) return;
    // A dialog pop of null from the barrier is "cancel". The dialog returns
    // a sentinel only when they tap Remove. See _GoalDialog.
    if (draft == _cleared) {
      setState(() => _saving = true);
      try {
        await SupabaseService.updateProgressGoal(record.id, null);
        ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(clearProgressGoal: true));
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save that goal.")));
        }
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    if (draft is! ProgressGoal) return;
    final withStart = draft.start != null
        ? draft
        : ProgressGoal(
            kind: draft.kind,
            field: draft.field,
            target: draft.target,
            unit: draft.unit,
            start: switch (draft.kind) {
              "lift" => liftEnds(record.workoutLogs, draft.field).$1,
              _ => measurementEnds(record.measurements, draft.kind == "weight" ? "weight" : draft.field).$1,
            },
          );
    setState(() => _saving = true);
    try {
      await SupabaseService.updateProgressGoal(record.id, withStart);
      ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(progressGoal: withStart));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save that goal.")));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(clientRecordProvider);
    final goal = record.progressGoal;
    if (goal == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
        child: AppCard(
          child: Row(
            children: [
              const Expanded(child: Text("Set a goal", style: TextStyle(fontWeight: FontWeight.w700))),
              TextButton(onPressed: _saving ? null : () => _edit(null), child: const Text("Add")),
            ],
          ),
        ),
      );
    }

    final (double? startReading, double? current) = switch (goal.kind) {
      "lift" => liftEnds(record.workoutLogs, goal.field),
      _ => measurementEnds(record.measurements, goal.kind == "weight" ? "weight" : goal.field),
    };
    final start = goal.start ?? startReading;
    final fraction = (start == null || current == null)
        ? 0.0
        : goalFraction(start: start, current: current, target: goal.target);
    final unit = goal.kind == "inches" ? "in" : "lb";

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(goal.label, style: const TextStyle(fontWeight: FontWeight.w800))),
                TextButton(onPressed: _saving ? null : () => _edit(goal), child: const Text("Edit")),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 10,
                backgroundColor: AppColors.line,
                color: AppColors.txt,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              current == null
                  ? "Log a ${goal.kind == "lift" ? "set" : "measurement"} to see progress. Target ${ _fmt(goal.target)} $unit."
                  : "${_fmt(current)} of ${_fmt(goal.target)} $unit",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(double n) => n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(1);
}

const ProgressGoal _cleared = ProgressGoal(kind: "cleared", field: "", target: 0);

class _GoalDialog extends StatefulWidget {
  const _GoalDialog({required this.current, required this.lifts});
  final ProgressGoal? current;
  final List<String> lifts;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late String _kind = widget.current?.kind == "inches" || widget.current?.kind == "lift" ? widget.current!.kind : "weight";
  late String _field = widget.current?.field.isNotEmpty == true ? widget.current!.field : "waist";
  late final TextEditingController _target = TextEditingController(
    text: widget.current == null ? "" : widget.current!.target.toString(),
  );
  late final TextEditingController _lift = TextEditingController(
    text: widget.current?.kind == "lift" ? widget.current!.field : (widget.lifts.isEmpty ? "" : widget.lifts.first),
  );

  @override
  void dispose() {
    _target.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _save() {
    final target = double.tryParse(_target.text.trim());
    if (target == null || target <= 0) return;
    final field = _kind == "weight" ? "weight" : _kind == "inches" ? _field : _lift.text.trim();
    if (field.isEmpty) return;
    Navigator.pop(
      context,
      ProgressGoal(
        kind: _kind,
        field: field,
        target: target,
        start: widget.current != null && widget.current!.kind == _kind && widget.current!.field == field
            ? widget.current!.start
            : null,
        unit: _kind == "inches" ? "in" : "lb",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text("Goal"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<String>(
              value: _kind,
              isExpanded: true,
              dropdownColor: AppColors.card,
              items: const [
                DropdownMenuItem(value: "weight", child: Text("Goal weight")),
                DropdownMenuItem(value: "inches", child: Text("Inches")),
                DropdownMenuItem(value: "lift", child: Text("A lift")),
              ],
              onChanged: (v) => setState(() => _kind = v ?? "weight"),
            ),
            if (_kind == "inches")
              DropdownButton<String>(
                value: ["chest", "waist", "hips", "arms", "thighs"].contains(_field) ? _field : "waist",
                isExpanded: true,
                dropdownColor: AppColors.card,
                items: const [
                  DropdownMenuItem(value: "chest", child: Text("Chest")),
                  DropdownMenuItem(value: "waist", child: Text("Waist")),
                  DropdownMenuItem(value: "hips", child: Text("Hips")),
                  DropdownMenuItem(value: "arms", child: Text("Arms")),
                  DropdownMenuItem(value: "thighs", child: Text("Thighs")),
                ],
                onChanged: (v) => setState(() => _field = v ?? "waist"),
              ),
            if (_kind == "lift")
              TextField(
                controller: _lift,
                decoration: const InputDecoration(labelText: "Exercise"),
              ),
            TextField(
              controller: _target,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: _kind == "inches" ? "Target inches" : "Target lb"),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(onPressed: () => Navigator.pop(context, _cleared), child: const Text("Remove")),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        TextButton(onPressed: _save, child: const Text("Save")),
      ],
    );
  }
}
