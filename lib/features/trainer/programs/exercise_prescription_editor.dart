import "package:flutter/material.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/exercise_prescription.dart";

/// Sets, reps, weight, rest, and notes for one exercise, opened after an
/// exchange so the old numbers are already filled in.
Future<ExercisePrescription?> showExercisePrescriptionEditor(BuildContext context, ExercisePrescription exercise) {
  return showModalBottomSheet<ExercisePrescription>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _Editor(exercise: exercise),
    ),
  );
}

class _Editor extends StatefulWidget {
  const _Editor({required this.exercise});
  final ExercisePrescription exercise;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final _sets = TextEditingController(text: "${widget.exercise.sets}");
  late final _reps = TextEditingController(text: "${widget.exercise.reps}");
  late final _weight = TextEditingController(text: widget.exercise.weight ?? "");
  late final _rest = TextEditingController(text: widget.exercise.rest ?? "");
  late final _notes = TextEditingController(text: widget.exercise.notes ?? "");

  @override
  void dispose() {
    _sets.dispose();
    _reps.dispose();
    _weight.dispose();
    _rest.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line));
    InputDecoration field(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: AppColors.mute),
          filled: true,
          fillColor: AppColors.bg,
          isDense: true,
          border: border,
          enabledBorder: border,
          focusedBorder: border,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.exercise.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.txt)),
          const SizedBox(height: 4),
          Text("Sets, reps, weight, rest, and notes carried over. Change anything that shouldn't stay.", style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: TextField(controller: _sets, keyboardType: TextInputType.number, style: TextStyle(color: AppColors.txt), decoration: field("Sets"))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _reps, keyboardType: TextInputType.number, style: TextStyle(color: AppColors.txt), decoration: field("Reps"))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: TextField(controller: _weight, style: TextStyle(color: AppColors.txt), decoration: field("Weight"))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _rest, style: TextStyle(color: AppColors.txt), decoration: field("Rest"))),
            ],
          ),
          const SizedBox(height: 8),
          TextField(controller: _notes, style: TextStyle(color: AppColors.txt), decoration: field("Notes")),
          const SizedBox(height: 14),
          BtnGold(
            onPressed: () {
              Navigator.pop(
                context,
                ExercisePrescription(
                  id: widget.exercise.id,
                  name: widget.exercise.name,
                  exerciseId: widget.exercise.exerciseId,
                  group: widget.exercise.group,
                  sets: int.tryParse(_sets.text.trim()) ?? widget.exercise.sets,
                  reps: int.tryParse(_reps.text.trim()) ?? widget.exercise.reps,
                  weight: _weight.text.trim().isEmpty ? null : _weight.text.trim(),
                  time: widget.exercise.time,
                  distance: widget.exercise.distance,
                  rest: _rest.text.trim().isEmpty ? null : _rest.text.trim(),
                  notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                  laterality: widget.exercise.laterality,
                  supersetId: widget.exercise.supersetId,
                  clientNoteText: widget.exercise.clientNoteText,
                  clientNoteAt: widget.exercise.clientNoteAt,
                ),
              );
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }
}
