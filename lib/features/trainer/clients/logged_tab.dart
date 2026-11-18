import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/utils/program_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/workout_log.dart";
import "../../../data/providers/trainer_providers.dart";
import "../../shared/workout_history_list.dart";

/// The same workout cards the client sees, plus a comment on each session.
class LoggedTab extends ConsumerStatefulWidget {
  const LoggedTab({super.key, required this.clientId});

  final String clientId;

  @override
  ConsumerState<LoggedTab> createState() => _LoggedTabState();
}

class _LoggedTabState extends ConsumerState<LoggedTab> {
  final Map<String, TextEditingController> _controllers = {};
  String? _savingId;

  TextEditingController _controllerFor(String logId, String? current) =>
      _controllers.putIfAbsent(logId, () => TextEditingController(text: current ?? ""));

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveComment(WorkoutHistoryCard card) async {
    final record = ref.read(trainerClientRecordsProvider)[widget.clientId];
    if (record == null) return;
    final text = _controllers[card.id]?.text.trim() ?? "";
    final matches = record.workoutLogs.where((l) => l.id == card.id);
    if (matches.isEmpty) return;
    final updated = WorkoutLogEntry(
      id: matches.first.id,
      date: matches.first.date,
      programId: matches.first.programId,
      programName: matches.first.programName,
      dayId: matches.first.dayId,
      dayTitle: matches.first.dayTitle,
      exercises: matches.first.exercises,
      loggedAt: matches.first.loggedAt,
      loggedBy: matches.first.loggedBy,
      loggedByName: matches.first.loggedByName,
      coachComment: text,
      coachCommentAt: stamp(),
    );
    setState(() => _savingId = card.id);
    try {
      await SupabaseService.appendWorkoutLog(widget.clientId, updated);
      final next = [
        for (final l in record.workoutLogs) l.id == updated.id ? updated : l,
      ];
      ref.read(trainerClientRecordsProvider.notifier).update(widget.clientId, (r) => r.copyWith(workoutLogs: next));
      if (text.isNotEmpty) {
        final info = ref.read(trainerRosterProvider).where((c) => c.id == widget.clientId);
        if (info.isNotEmpty) {
          notifyCoachComment(toEmail: info.first.email ?? "", toName: info.first.name, kind: "workout session", profileId: info.first.id);
        }
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Comment saved.")));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save — check your connection and try again.")));
    } finally {
      if (mounted) setState(() => _savingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(trainerClientRecordsProvider)[widget.clientId];
    final cards = record == null ? const <WorkoutHistoryCard>[] : workoutHistory(record);
    if (cards.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: HintBox(text: "Nothing logged yet for this client."),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("Logged sessions"),
          WorkoutHistoryList(
            cards: cards,
            commentBuilder: (card) => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("COACH COMMENT", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.mute, letterSpacing: 0.5)),
                  const SizedBox(height: 6),
                  AppField(
                    controller: _controllerFor(card.id, card.coachComment),
                    placeholder: "Leave a note on this session…",
                    maxLines: 2,
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: BtnGhost(
                      onPressed: _savingId == card.id ? null : () => _saveComment(card),
                      child: Text(_savingId == card.id ? "Saving…" : "Save comment"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
