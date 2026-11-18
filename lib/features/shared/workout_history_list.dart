import "package:flutter/material.dart";
import "../../core/theme/app_colors.dart";
import "../../core/utils/date_utils.dart";
import "../../core/utils/program_utils.dart";

/// One card per saved workout. Black, gray and white, matching the rest of
/// the app. Tapping a card opens every set.
class WorkoutHistoryList extends StatelessWidget {
  const WorkoutHistoryList({
    super.key,
    required this.cards,
    this.commentBuilder,
  });

  final List<WorkoutHistoryCard> cards;

  /// Coach Logged tab adds a comment box under the sets.
  final Widget Function(WorkoutHistoryCard card)? commentBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final card in cards)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _HistoryCard(card: card, comment: commentBuilder?.call(card)),
          ),
      ],
    );
  }
}

class _HistoryCard extends StatefulWidget {
  const _HistoryCard({required this.card, this.comment});
  final WorkoutHistoryCard card;
  final Widget? comment;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final marks = [
      if (card.cycleCheck) "Done",
      if (card.pr) "PR",
      if (card.improved && !card.pr) "Up",
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          card.dayTitle.isEmpty ? "Workout" : card.dayTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.txt),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppColors.mute),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "${niceDate(card.date)} · Logged by ${card.who}",
                    style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.3),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        "${card.exerciseCount} exercise${card.exerciseCount == 1 ? "" : "s"}, ${card.setCount} set${card.setCount == 1 ? "" : "s"}",
                        style: TextStyle(fontSize: 12, color: AppColors.txt, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        "${_fmt(card.volume)} lb volume",
                        style: TextStyle(fontSize: 12, color: AppColors.mute),
                      ),
                      for (final mark in marks)
                        Text(mark, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.txt)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: AppColors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final ex in card.exercises) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(ex.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.txt)),
                    ),
                    for (final s in ex.sets)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          "Set ${s.setNum}  ${_fmt(s.weight)} lb × ${s.reps}"
                          "${_change("weight", s.weightMark, s.prevWeight, s.weight)}"
                          "${_change("reps", s.repsMark, s.prevReps?.toDouble(), s.reps.toDouble())}",
                          style: TextStyle(fontSize: 13, color: AppColors.txt, height: 1.35),
                        ),
                      ),
                  ],
                  if (widget.comment != null) widget.comment!,
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _fmt(double n) => n % 1 == 0 ? n.toInt().toString() : n.toStringAsFixed(1);

String _change(String label, String mark, double? prev, double current) {
  if (mark.isEmpty || prev == null) return "";
  final arrow = mark == "up" ? "↑" : (mark == "down" ? "↓" : "=");
  return "  $label $arrow ${_fmt(prev)} to ${_fmt(current)}";
}
