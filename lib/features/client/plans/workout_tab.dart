import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/workout_logging.dart";
import "../../../core/legal/health_sources.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/source_citations.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/motion/motion.dart";
import "../../../core/motion/stagger_in.dart";
import "../../../core/utils/workout_week.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_record.dart";
import "../../../data/models/comm_message.dart";
import "../../../data/models/exercise_prescription.dart";
import "../../../data/models/program_day.dart";
import "../../../data/models/saved_program.dart";
import "../../../data/models/workout_log.dart";
import "../../../data/providers/client_providers.dart";
import "../../shared/session_logger_view.dart";
import "../beep/beep_bar.dart";

/// Mirrors ClientWorkoutWithNotes.jsx: overview day list -> active logging
/// session -> saved confirmation (SessionLoggerView, shared with the
/// coach's own Start Session flow — see trainer_home_screen.dart), plus a
/// per-exercise note that can be saved locally or sent straight into the
/// Chat log — a client-only concern, so it wraps the shared logger rather
/// than living inside it.
class WorkoutTab extends ConsumerStatefulWidget {
  const WorkoutTab({super.key});

  @override
  ConsumerState<WorkoutTab> createState() => _WorkoutTabState();
}

class _NoteTarget {
  const _NoteTarget({
    required this.progId,
    required this.dayId,
    required this.exId,
    required this.exName,
  });
  final String progId;
  final String dayId;
  final String exId;
  final String exName;
}

class _WorkoutTabState extends ConsumerState<WorkoutTab> {
  String? _loggingDayId;
  String? _openDayId;

  Future<void> _saveSession(WorkoutLogEntry entry) async {
    final client = ref.read(clientRecordProvider);
    // Same id = the same live session: replace, never log it twice.
    final updatedLogs = [
      ...client.workoutLogs.where((l) => l.id != entry.id),
      entry,
    ];
    await SupabaseService.appendWorkoutLog(client.id, entry);
    final info = ref.read(clientInfoProvider);
    flagSessionSwaps(
      entry: entry,
      clientName: info.name,
      coachId: info.primaryTrainerId,
    );
    await SupabaseService.awardAutomaticPoints(
      client.id,
      "workout_streak",
      "scan",
    );
    final freshBadges = await SupabaseService.loadMeritBadgesFor(client.id);
    ref
        .read(earnedBadgesProvider.notifier)
        .replaceForClient(client.id, freshBadges);
    ref
        .read(clientRecordProvider.notifier)
        .update(
          (r) => r.copyWith(
            workoutLogs: updatedLogs,
            loggedDates: r.loggedDates.contains(isoToday())
                ? r.loggedDates
                : [...r.loggedDates, isoToday()],
          ),
        );
  }

  void _openNoteSheet(_NoteTarget target, String? existingNote) {
    final controller = TextEditingController(text: "");
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final hasText = controller.text.trim().isNotEmpty;
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: 20 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Note on ${target.exName}",
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Your coach will be notified.",
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    maxLines: 4,
                    autofocus: true,
                    style: TextStyle(color: AppColors.txt, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: "e.g. Left shoulder feels tight on this one",
                      hintStyle: TextStyle(color: AppColors.mute),
                      filled: true,
                      fillColor: AppColors.bg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.line),
                      ),
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: !hasText
                              ? null
                              : () {
                                  _saveNote(
                                    target,
                                    controller.text.trim(),
                                    sendToCoach: false,
                                  );
                                  Navigator.of(sheetContext).pop();
                                },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.gold,
                            side: BorderSide(color: AppColors.goldDim),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          child: const Text(
                            "Save Note",
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: BtnGold(
                          onPressed: !hasText
                              ? null
                              : () {
                                  _saveNote(
                                    target,
                                    controller.text.trim(),
                                    sendToCoach: true,
                                  );
                                  Navigator.of(sheetContext).pop();
                                },
                          child: const Text(
                            "Send to Coach",
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(
                      "Cancel",
                      style: TextStyle(color: AppColors.mute, fontSize: 12),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _saveNote(_NoteTarget target, String text, {required bool sendToCoach}) {
    ref.read(clientRecordProvider.notifier).update((r) {
      final updatedPrograms = r.savedPrograms.map((prog) {
        if (prog.id != target.progId) return prog;
        return prog.copyWith(
          programDays: prog.programDays.map((day) {
            if (day.id != target.dayId) return day;
            return day.copyWith(
              exercises: day.exercises
                  .map(
                    (ex) => ex.id == target.exId
                        ? ex.copyWith(
                            clientNoteText: text,
                            clientNoteAt: stamp(),
                          )
                        : ex,
                  )
                  .toList(),
            );
          }).toList(),
        );
      }).toList();

      var comms = r.comms;
      if (sendToCoach) {
        final entry = CommMessage(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          who: "client",
          text: "\u{1F4DD} Workout note on ${target.exName}: $text",
          at: stamp(),
          trainerId: null,
        );
        comms = [entry, ...comms];
      }
      return r.copyWith(savedPrograms: updatedPrograms, comms: comms);
    });

    if (sendToCoach && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✓ Note sent to your coach.")),
      );
    }
  }

  Widget _exerciseFooter(
    SavedProgram prog,
    ProgramDay day,
    ExercisePrescription ex,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ex.clientNoteText != null && ex.clientNoteText!.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.06),
              border: Border.all(color: AppColors.danger),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              "\u{1F4DD} ${ex.clientNoteText}",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => _openNoteSheet(
                _NoteTarget(
                  progId: prog.id,
                  dayId: day.id,
                  exId: ex.id,
                  exName: ex.name,
                ),
                ex.clientNoteText,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.mute,
                side: BorderSide(color: AppColors.line),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                ex.clientNoteText != null && ex.clientNoteText!.isNotEmpty
                    ? "\u{1F4DD} Edit Note"
                    : "+ Note",
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientRecordProvider);
    final Widget page;
    if (_loggingDayId != null) {
      page = Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _loggingDayId = null),
              icon: Icon(Icons.chevron_left, color: AppColors.txt),
              label: Text(
                "Program",
                style: TextStyle(
                  color: AppColors.txt,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Expanded(
            child: SessionLoggerView(
              client: client,
              authorName: ref.watch(clientInfoProvider).name,
              authorRole: "client",
              onSave: _saveSession,
              initialDayId: _loggingDayId,
              exerciseFooterBuilder: _exerciseFooter,
              beepBarBuilder: (names, focusIndex, fullView) => BeepBar(
                exerciseNames: names,
                focusIndex: focusIndex,
                fullView: fullView,
              ),
              footer: const Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: SourceCitations(
                  sources: kTrainingSources,
                  disclaimer: kTrainingDisclaimer,
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      page = _programPage(client);
    }
    return AnimatedSwitcher(
      duration: reduceMotionOf(context)
          ? const Duration(milliseconds: 80)
          : motionExpand,
      child: KeyedSubtree(key: ValueKey(_loggingDayId ?? "plan"), child: page),
    );
  }

  Widget _programPage(ClientRecord client) {
    final programs = client.savedPrograms
        .where((p) => p.status == "active" && p.programDays.isNotEmpty)
        .toList();
    if (programs.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: [
          Text(
            "No active workout program yet. Your coach will assign one to your profile.",
            style: TextStyle(color: AppColors.mute, height: 1.4),
          ),
        ],
      );
    }

    final days = programs.first.programDays;
    final checked = currentCycleCheckedDays(
      programDayIds: [for (final day in days) day.id],
      logs: client.workoutLogs,
    );
    final openId = days.any((day) => day.id == _openDayId) ? _openDayId : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        Text(
          checked.isEmpty
              ? "New round"
              : "${checked.length} of ${days.length} done",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.mute,
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < days.length; i++)
          StaggerIn(
            key: ValueKey("program-day-$i-${days[i].id}"),
            index: i,
            child: _ProgramDayTile(
              number: i + 1,
              day: days[i],
              checked: checked.contains(days[i].id),
              open: openId == days[i].id,
              onToggle: () => setState(() {
                _openDayId = _openDayId == days[i].id ? null : days[i].id;
              }),
              onStart: () => setState(() => _loggingDayId = days[i].id),
            ),
          ),
      ],
    );
  }
}

class _ProgramDayTile extends StatelessWidget {
  const _ProgramDayTile({
    required this.number,
    required this.day,
    required this.checked,
    required this.open,
    required this.onToggle,
    required this.onStart,
  });

  final int number;
  final ProgramDay day;
  final bool checked;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final reduce = reduceMotionOf(context);
    final title = day.title.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              // A boundary, so the exercises underneath stay their own labels.
              container: true,
              button: true,
              expanded: open,
              excludeSemantics: true,
              label: checked ? "Day $number, completed" : "Day $number",
              value: title.isEmpty ? null : title,
              onTap: onToggle,
              child: TapHighlight(
                onTap: onToggle,
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(12),
                  bottom: open ? Radius.zero : const Radius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
                  child: Row(
                    children: [
                      Text(
                        "Day $number",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: AppColors.txt,
                        ),
                      ),
                      if (title.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.mute,
                            ),
                          ),
                        ),
                      ] else
                        const Spacer(),
                      if (checked) ...[
                        Icon(Icons.check, size: 16, color: AppColors.txt),
                        const SizedBox(width: 6),
                      ],
                      Icon(
                        open ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: AppColors.mute,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: reduce
                  ? const Duration(milliseconds: 80)
                  : motionExpand,
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: open
                  ? _openBody()
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _openBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onStart,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.bg,
                backgroundColor: AppColors.txt,
                side: BorderSide(color: AppColors.txt),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text(
                "Start workout",
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          if (day.exercises.isNotEmpty) const SizedBox(height: 12),
          for (var i = 0; i < day.exercises.length; i++)
            StaggerIn(
              index: i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day.exercises[i].name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.txt,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "${day.exercises[i].sets} sets · ${day.exercises[i].reps} reps${(day.exercises[i].weight ?? "").isEmpty ? "" : " · ${day.exercises[i].weight}"}",
                        style: TextStyle(fontSize: 12, color: AppColors.mute),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
