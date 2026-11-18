import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/live_log/live_log_store.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/program_utils.dart";
import "../../../core/utils/weight_suggestion.dart";
import "../../../core/widgets/exercise_video.dart";
import "../../../data/models/client_record.dart";
import "../../../data/models/exercise_prescription.dart";
import "../../../data/providers/trainer_providers.dart";

/// One set's live (unsaved) input while a session is in progress.
class SetDraft {
  SetDraft({this.reps, this.weight});
  int? reps;
  double? weight;
}

/// Mirrors ExerciseSetGrid.jsx, trimmed to the interactive logging grid
/// (name/unilateral tag, prescribed weight/time/distance/rest, notes, and
/// the sets-as-columns grid) — canonical-exercise metadata (video, cues,
/// equipment, tempo) belongs to the not-yet-built Exercise Library feature.
///
/// Built on a [Table] rather than two independent [Column]s for the label
/// strip and the value columns — Table guarantees every row lines up across
/// columns by construction, which a hand-tuned pair of Columns does not
/// (their per-row paddings drift out of sync over several rows).
class ExerciseSetGrid extends StatefulWidget {
  const ExerciseSetGrid({
    super.key,
    required this.exercise,
    required this.client,
    required this.sessionData,
    required this.onSetChange,
    required this.dayId,
    this.syncTick = 0,
    this.logStore,
    this.sessionId = "",
    this.clientId = "",
    this.coachLed = false,
  });

  final ExercisePrescription exercise;
  final ClientRecord client;
  final Map<String, SetDraft> sessionData;
  final void Function(String exerciseName, int setNum, String field, Object? value) onSetChange;
  final String? dayId;

  /// Where every keystroke is saved, keyed by session, client, exercise and set.
  final LiveLogStore? logStore;
  final String sessionId;
  final String clientId;

  String get logExerciseId {
    final catalogId = exercise.exerciseId;
    if (catalogId != null && catalogId.isNotEmpty) return catalogId;
    return exercise.id;
  }

  /// Bumped by the parent when the shared live log changed from another
  /// device, so the boxes redraw with what the coach (or client) just entered.
  final int syncTick;

  /// A coach logging for the client sees a short note. The client logging
  /// their own session sees the same suggestion written out.
  final bool coachLed;

  @override
  State<ExerciseSetGrid> createState() => _ExerciseSetGridState();
}

class _ExerciseSetGridState extends State<ExerciseSetGrid> {
  static const _unit = "lbs";
  late List<TextEditingController> _repsControllers;
  late List<TextEditingController> _weightControllers;
  late List<FocusNode> _repsFocus;
  late List<FocusNode> _weightFocus;

  @override
  void initState() {
    super.initState();
    _buildControllers();
  }

  @override
  void didUpdateWidget(covariant ExerciseSetGrid old) {
    super.didUpdateWidget(old);
    final identityChanged = old.clientId != widget.clientId ||
        old.sessionId != widget.sessionId ||
        old.exercise.id != widget.exercise.id ||
        old.logExerciseId != widget.logExerciseId;
    if (identityChanged) {
      _disposeControllers();
      _buildControllers();
    } else if (old.syncTick != widget.syncTick) {
      _pullFromStore();
    }
  }

  String _stored(String field, int setNum) {
    final store = widget.logStore;
    if (store == null) return "";
    return store.raw(
          sessionId: widget.sessionId,
          clientId: widget.clientId,
          exerciseId: widget.logExerciseId,
          setIndex: setNum,
          field: field,
        ) ??
        "";
  }

  void _remember(String field, int setNum, String raw) {
    widget.logStore?.remember(
      sessionId: widget.sessionId,
      clientId: widget.clientId,
      exerciseId: widget.logExerciseId,
      setIndex: setNum,
      field: field,
      raw: raw,
      at: DateTime.now().toUtc(),
    );
  }

  /// Shows the saved text for this client and exercise. Never writes a
  /// shorter number over what is already in the box, and never touches a
  /// box the coach is typing in.
  void _pullFromStore() {
    final store = widget.logStore;
    if (store == null) return;
    for (var i = 0; i < _repsControllers.length; i++) {
      final setNum = i + 1;
      if (!_repsFocus[i].hasFocus) {
        final want = _stored("reps", setNum);
        if (want.isNotEmpty && _repsControllers[i].text != want) {
          _repsControllers[i].text = want;
        }
      }
      if (!_weightFocus[i].hasFocus) {
        final want = _stored("weight", setNum);
        if (want.isNotEmpty && _weightControllers[i].text != want) {
          _weightControllers[i].text = want;
        }
      }
    }
  }

  void _buildControllers() {
    final numSets = widget.exercise.sets > 0 ? widget.exercise.sets : 3;
    _repsControllers = List.generate(numSets, (i) {
      final saved = _stored("reps", i + 1);
      final draft = widget.sessionData["${widget.logExerciseId}__${i + 1}"] ??
          widget.sessionData["${widget.exercise.name}__${i + 1}"];
      return TextEditingController(text: saved.isNotEmpty ? saved : (draft?.reps?.toString() ?? ""));
    });
    _weightControllers = List.generate(numSets, (i) {
      final saved = _stored("weight", i + 1);
      final draft = widget.sessionData["${widget.logExerciseId}__${i + 1}"] ??
          widget.sessionData["${widget.exercise.name}__${i + 1}"];
      final fallback = draft?.weight == null ? "" : _fmtNum(draft!.weight!);
      return TextEditingController(text: saved.isNotEmpty ? saved : fallback);
    });
    _repsFocus = List.generate(numSets, (_) => FocusNode());
    _weightFocus = List.generate(numSets, (_) => FocusNode());
  }

  void _disposeControllers() {
    for (final c in _repsControllers) {
      c.dispose();
    }
    for (final c in _weightControllers) {
      c.dispose();
    }
    for (final f in [..._repsFocus, ..._weightFocus]) {
      f.dispose();
    }
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final exercise = widget.exercise;
    final numSets = exercise.sets > 0 ? exercise.sets : 3;
    final sets = List.generate(numSets, (i) => i + 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(exercise.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            if (exercise.laterality == "unilateral") ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.goldDim),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  "UNILATERAL",
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppColors.gold, letterSpacing: 0.5),
                ),
              ),
            ],
          ],
        ),
        Consumer(builder: (context, ref, _) {
          final catalog = ref.watch(exerciseCatalogProvider);
          final matches = catalog.where((d) =>
              (exercise.exerciseId != null && d.id == exercise.exerciseId) ||
              (exercise.exerciseId == null && d.name.toLowerCase() == exercise.name.toLowerCase()));
          final equipment = matches.isEmpty ? const <String>[] : matches.first.equipment;
          final bump = suggestWeightIncrease(
            logs: widget.client.workoutLogs,
            exerciseName: exercise.name,
            targetReps: exercise.reps,
            targetWeight: parseTargetWeight(exercise.weight),
            kind: plateKindFor(equipment),
          );
          if (bump == null) return const SizedBox.shrink();
          final pounds = _fmtNum(bump);
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.coachLed ? "suggested $pounds lb" : "Try $pounds lb next time",
              style: TextStyle(
                fontSize: widget.coachLed ? 11 : 13,
                fontWeight: widget.coachLed ? FontWeight.w500 : FontWeight.w600,
                color: widget.coachLed ? AppColors.mute : AppColors.txt,
              ),
            ),
          );
        }),
        if (exercise.weight != null || exercise.time != null || exercise.distance != null || exercise.rest != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (exercise.weight != null)
                  Text("@ ${exercise.weight} $_unit", style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w600)),
                if (exercise.time != null)
                  Text("Time: ${exercise.time}", style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w600)),
                if (exercise.distance != null)
                  Text("Distance: ${exercise.distance}", style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w600)),
                if (exercise.rest != null)
                  Text("Rest: ${exercise.rest}", style: TextStyle(fontSize: 12, color: AppColors.mute, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        if (exercise.notes != null && exercise.notes!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(exercise.notes!, style: TextStyle(fontSize: 12, color: AppColors.mute, fontStyle: FontStyle.italic)),
          ),
        // The catalogue's coaching cues are for the client — how to do the
        // movement. Its coachNotes are deliberately not read here: those are
        // the coach's private notes about the exercise and never reach the
        // client's screen.
        // The demo clip a coach filmed comes from the same catalogue entry,
        // so both are resolved from one lookup.
        Consumer(builder: (context, ref, _) {
          final catalog = ref.watch(exerciseCatalogProvider);
          final matches = catalog.where((d) =>
              (exercise.exerciseId != null && d.id == exercise.exerciseId) ||
              (exercise.exerciseId == null && d.name.toLowerCase() == exercise.name.toLowerCase()));
          final def = matches.isEmpty ? null : matches.first;
          final cues = (def?.cues ?? "").trim();
          final videoPath = def?.videoPath ?? "";
          if (cues.isEmpty && videoPath.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (videoPath.isNotEmpty)
                  WatchDemoButton(title: exercise.name, videoPath: videoPath),
                if (videoPath.isNotEmpty && cues.isNotEmpty) const SizedBox(height: 6),
                if (cues.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.gold.withValues(alpha: 0.08),
                      border: Border.all(color: AppColors.goldDim),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("CUES", style: TextStyle(fontSize: 9.5, color: AppColors.gold, fontWeight: FontWeight.w800, letterSpacing: 1)),
                        const SizedBox(height: 2),
                        Text(cues, style: TextStyle(fontSize: 12, color: AppColors.txt, height: 1.4)),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: {
              0: const FixedColumnWidth(96),
              for (final n in sets) n: const FixedColumnWidth(76),
            },
            children: [
              TableRow(children: [
                const SizedBox(),
                for (final n in sets)
                  Padding(
                    padding: const EdgeInsets.only(left: 5, bottom: 4),
                    child: Text(
                      "SET $n",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.mute, letterSpacing: 0.4),
                    ),
                  ),
              ]),
              TableRow(children: [
                const _RowLabel("Target reps"),
                for (final n in sets) _targetRepsCell(exercise, n),
              ]),
              TableRow(children: [
                const _RowLabel("Reps Cmpl."),
                for (final n in sets) _repsInputCell(exercise, n),
              ]),
              TableRow(children: [
                _RowLabel("Last Wt ($_unit)"),
                for (final n in sets) _lastWeightCell(exercise, n),
              ]),
              TableRow(children: [
                _RowLabel("Wt ($_unit)"),
                for (final n in sets) _weightInputCell(exercise, n),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cellWrap(Widget child) => Padding(padding: const EdgeInsets.only(left: 5, top: 2.5, bottom: 2.5), child: child);

  Widget _targetRepsCell(ExercisePrescription exercise, int setNum) {
    return _cellWrap(Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.07),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.19)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        exercise.reps > 0 ? "${exercise.reps}" : "—",
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.gold),
      ),
    ));
  }

  Widget _repsInputCell(ExercisePrescription exercise, int setNum) {
    final draft = widget.sessionData["${exercise.name}__$setNum"];
    final reps = draft?.reps;
    final hit = reps != null && exercise.reps > 0 && reps >= exercise.reps;
    return _cellWrap(Container(
      decoration: BoxDecoration(
        color: hit ? AppColors.grn : AppColors.card,
        border: Border.all(color: hit ? AppColors.grn : AppColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: _repsControllers[setNum - 1],
        focusNode: _repsFocus[setNum - 1],
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: hit ? AppColors.onGold : AppColors.txt),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 7),
          border: InputBorder.none,
          hintText: exercise.reps > 0 ? "${exercise.reps}" : "",
          hintStyle: TextStyle(color: AppColors.mute),
        ),
        onChanged: (v) {
          _remember("reps", setNum, v);
          widget.onSetChange(exercise.name, setNum, "reps", liveLogReps(v));
          setState(() {});
        },
      ),
    ));
  }

  Widget _lastWeightCell(ExercisePrescription exercise, int setNum) {
    final last = getLastSetData(widget.client, exercise.name, setNum, widget.dayId);
    final suggested = double.tryParse(exercise.weight ?? "");
    final label = last.weight > 0 ? "${_fmtNum(last.weight)}×${last.reps}" : (suggested != null ? "Sugg. ${_fmtNum(suggested)}" : "—");
    return _cellWrap(Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(color: AppColors.bg, border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(8)),
      child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.mute)),
    ));
  }

  Widget _weightInputCell(ExercisePrescription exercise, int setNum) {
    final draft = widget.sessionData["${exercise.name}__$setNum"];
    final weight = draft?.weight;
    final last = getLastSetData(widget.client, exercise.name, setNum, widget.dayId);
    final hasPrev = last.weight > 0;
    final suggested = double.tryParse(exercise.weight ?? "");
    final entered = weight != null && weight > 0;

    Color bg = AppColors.card, border = AppColors.line, color = AppColors.txt;
    if (entered && hasPrev) {
      if (weight > last.weight) {
        bg = AppColors.statusGreen.withValues(alpha: 0.14);
        border = AppColors.statusGreen;
        color = AppColors.statusGreen;
      } else if (weight == last.weight) {
        bg = AppColors.mute.withValues(alpha: 0.12);
        border = AppColors.mute;
        color = AppColors.mute;
      } else {
        bg = AppColors.danger.withValues(alpha: 0.12);
        border = AppColors.danger;
        color = AppColors.danger;
      }
    } else if (entered && suggested != null) {
      if (weight > suggested) {
        bg = AppColors.statusGreen.withValues(alpha: 0.14);
        border = AppColors.statusGreen;
        color = AppColors.statusGreen;
      } else if (weight == suggested) {
        bg = AppColors.mute.withValues(alpha: 0.12);
        border = AppColors.mute;
        color = AppColors.mute;
      } else {
        bg = AppColors.danger.withValues(alpha: 0.12);
        border = AppColors.danger;
        color = AppColors.danger;
      }
    } else if (entered) {
      bg = AppColors.statusGreen.withValues(alpha: 0.14);
      border = AppColors.statusGreen;
      color = AppColors.statusGreen;
    }

    return _cellWrap(Container(
      decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(8)),
      child: TextField(
        controller: _weightControllers[setNum - 1],
        focusNode: _weightFocus[setNum - 1],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 7),
          border: InputBorder.none,
          hintText: last.weight > 0 ? _fmtNum(last.weight) : (suggested != null ? _fmtNum(suggested) : ""),
          hintStyle: TextStyle(color: AppColors.mute),
        ),
        onChanged: (v) {
          _remember("weight", setNum, v);
          widget.onSetChange(exercise.name, setNum, "weight", liveLogWeight(v));
          setState(() {});
        },
      ),
    ));
  }
}

class _RowLabel extends StatelessWidget {
  const _RowLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Text(text, style: TextStyle(fontSize: 12, color: AppColors.mute)),
    );
  }
}

String _fmtNum(double n) => n % 1 == 0 ? n.toInt().toString() : n.toString();
