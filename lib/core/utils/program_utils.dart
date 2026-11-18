import "../../data/models/client_record.dart";
import "../../data/models/program_day.dart";
import "../../data/models/workout_log.dart";

class LastSetData {
  const LastSetData({this.weight = 0, this.reps = 0});
  final double weight;
  final int reps;
}

/// Mirrors programHelpers.js `getLastSetData` — most recent COMPLETED weight
/// for a given exercise + set number, scoped strictly to one workout day.
LastSetData getLastSetData(
  ClientRecord client,
  String exerciseName,
  int setNum,
  String? dayId,
) {
  var logs = client.workoutLogs.reversed.toList(); // newest first
  if (dayId != null) logs = logs.where((l) => l.dayId == dayId).toList();
  for (final log in logs) {
    final ex = log.exercises.where((e) => e.name == exerciseName);
    if (ex.isEmpty) continue;
    final set = ex.first.sets.where((s) => s.setNum == setNum && s.completed);
    if (set.isNotEmpty) {
      return LastSetData(
        weight: set.first.completedWeight ?? 0,
        reps: set.first.completedReps ?? 0,
      );
    }
  }
  return const LastSetData();
}

/// Mirrors programHelpers.js `getCurrentCycleCompletedDays` — which days in
/// the current split cycle have been logged since the last time every day
/// was completed (at which point the cycle resets and starts counting fresh).
Set<String> getCurrentCycleCompletedDays(
  ClientRecord client,
  List<ProgramDay> programDays,
) {
  final dayIds = programDays.map((d) => d.id).toList();
  if (dayIds.isEmpty) return {};
  final dayIdSet = dayIds.toSet();

  // The cycle turns over on the COMMITTED days alone. Suggested days are
  // optional by design — "up to 2", added only when they help — so counting
  // them here would mean a client who completes every session they committed
  // to never finishes a cycle, and their ticks pile up indefinitely for the
  // offence of skipping an optional walk. Logging a suggested day still
  // registers below, so it still shows its tick; it just isn't a gate.
  final gateIds = programDays.where((d) => !d.suggested).map((d) => d.id).toSet();
  final effectiveGate = gateIds.isEmpty ? dayIdSet : gateIds;

  final sessions =
      client.workoutLogs
          .where((log) => dayIdSet.contains(log.dayId))
          .map((log) => (dayId: log.dayId, sortKey: log.loggedAt ?? log.date))
          .toList()
        ..sort((a, b) => a.sortKey.compareTo(b.sortKey));

  var completedThisCycle = <String>{};
  for (final s in sessions) {
    completedThisCycle.add(s.dayId);
    if (completedThisCycle.containsAll(effectiveGate)) {
      completedThisCycle = {}; // every committed day hit — start fresh
    }
  }
  return completedThisCycle;
}

class ProgramNote {
  const ProgramNote({
    required this.label,
    required this.text,
    required this.at,
  });
  final String label;
  final String text;
  final String at;
}

/// Mirrors programHelpers.js `getClientProgramNotes`.
List<ProgramNote> getClientProgramNotes(ClientRecord client) {
  final notes = <ProgramNote>[];
  for (final prog in client.savedPrograms) {
    for (final day in prog.programDays) {
      for (final ex in day.exercises) {
        if (ex.clientNoteText != null && ex.clientNoteText!.isNotEmpty) {
          notes.add(
            ProgramNote(
              label: ex.name,
              text: ex.clientNoteText!,
              at: ex.clientNoteAt ?? "",
            ),
          );
        }
      }
    }
  }
  return notes;
}

class SetProgression {
  const SetProgression({
    required this.setNum,
    this.prevWeight,
    required this.weight,
    required this.reps,
    this.direction,
  });
  final int setNum;
  final double? prevWeight;
  final double weight;
  final int reps;
  final String?
  direction; // "up" | "down" | "same" | null (no prior set to compare)
}

class ExerciseProgression {
  const ExerciseProgression({
    required this.name,
    required this.direction,
    required this.sets,
  });
  final String name;
  final String direction; // "up" | "down" | "same" | "new"
  final List<SetProgression> sets;
}

class DayProgression {
  const DayProgression({
    required this.dayId,
    required this.dayTitle,
    required this.date,
    required this.exercises,
    required this.sourceId,
    required this.loggedBy,
    this.loggedByName,
  });
  final String dayId;
  final String dayTitle;
  final String date;
  final List<ExerciseProgression> exercises;
  final String sourceId;

  /// "client" (self-logged) | "coach" — see WorkoutLogEntry.loggedBy.
  final String loggedBy;
  final String? loggedByName;
}

class _RawSession {
  _RawSession({
    required this.date,
    required this.dayId,
    required this.dayTitle,
    required this.sourceId,
    required this.exercises,
    required this.loggedBy,
    this.loggedByName,
  });
  final String date;
  final String dayId;
  final String dayTitle;
  final String sourceId;
  final String loggedBy;
  final String? loggedByName;
  final List<
    ({String name, List<({int setNum, double weight, int reps})> sets})
  >
  exercises;
}

String _direction(num curr, num prev) =>
    curr > prev ? "up" : (curr < prev ? "down" : "same");

/// Mirrors programHelpers.js `getDayProgressionSummary` — compares each
/// workout day's most recent logged session against the one before it, so
/// History can show whether each exercise/set trended up, down, or held.
List<DayProgression> getDayProgressionSummary(ClientRecord client) {
  final raw = <_RawSession>[];
  for (final log in client.workoutLogs) {
    final exercises =
        <({String name, List<({int setNum, double weight, int reps})> sets})>[];
    for (final ex in log.exercises) {
      final doneSets = ex.sets
          .where((s) => s.completed)
          .map(
            (s) => (
              setNum: s.setNum,
              weight: s.completedWeight ?? 0,
              reps: s.completedReps ?? 0,
            ),
          )
          .toList();
      if (doneSets.isNotEmpty) exercises.add((name: ex.name, sets: doneSets));
    }
    raw.add(
      _RawSession(
        date: log.date,
        dayId: log.dayId,
        dayTitle: log.dayTitle,
        sourceId: log.id,
        exercises: exercises,
        loggedBy: log.loggedBy,
        loggedByName: log.loggedByName,
      ),
    );
  }
  raw.sort((a, b) => a.date.compareTo(b.date));

  final byDay = <String, List<_RawSession>>{};
  for (final session in raw) {
    byDay.putIfAbsent(session.dayId, () => []).add(session);
  }

  final days = <DayProgression>[];
  byDay.forEach((dayId, sessions) {
    if (sessions.isEmpty) return;
    final current = sessions.last;
    final previous = sessions.length > 1 ? sessions[sessions.length - 2] : null;

    final exercises = current.exercises.map((ex) {
      final prevExMatches =
          previous?.exercises.where((p) => p.name == ex.name) ??
          const Iterable.empty();
      final prevEx = prevExMatches.isNotEmpty ? prevExMatches.first : null;
      final sets = ex.sets.map((s) {
        final prevSetMatches =
            prevEx?.sets.where((p) => p.setNum == s.setNum) ??
            const Iterable.empty();
        final prevSet = prevSetMatches.isNotEmpty ? prevSetMatches.first : null;
        return SetProgression(
          setNum: s.setNum,
          prevWeight: prevSet?.weight,
          weight: s.weight,
          reps: s.reps,
          direction: prevSet != null
              ? _direction(s.weight, prevSet.weight)
              : null,
        );
      }).toList();

      String exerciseDir;
      if (sets.any((s) => s.direction == "up")) {
        exerciseDir = "up";
      } else if (sets.any((s) => s.direction == "down")) {
        exerciseDir = "down";
      } else if (sets.any((s) => s.direction == "same")) {
        exerciseDir = "same";
      } else {
        exerciseDir = "new";
      }
      return ExerciseProgression(
        name: ex.name,
        direction: exerciseDir,
        sets: sets,
      );
    }).toList();

    days.add(
      DayProgression(
        dayId: dayId,
        dayTitle: current.dayTitle,
        date: current.date,
        exercises: exercises,
        sourceId: current.sourceId,
        loggedBy: current.loggedBy,
        loggedByName: current.loggedByName,
      ),
    );
  });

  days.sort(
    (a, b) => b.date.compareTo(a.date),
  ); // most recently completed day first
  return days;
}

/// One saved workout, newest first. Older sessions stay on the list.
class WorkoutHistorySet {
  const WorkoutHistorySet({
    required this.setNum,
    required this.reps,
    required this.weight,
    this.prevReps,
    this.prevWeight,
  });
  final int setNum;
  final int reps;
  final double weight;
  final int? prevReps;
  final double? prevWeight;

  String get weightMark {
    if (prevWeight == null) return "";
    if (weight > prevWeight!) return "up";
    if (weight < prevWeight!) return "down";
    return "same";
  }

  String get repsMark {
    if (prevReps == null) return "";
    if (reps > prevReps!) return "up";
    if (reps < prevReps!) return "down";
    return "same";
  }
}

class WorkoutHistoryExercise {
  const WorkoutHistoryExercise({required this.name, required this.sets});
  final String name;
  final List<WorkoutHistorySet> sets;
}

class WorkoutHistoryCard {
  const WorkoutHistoryCard({
    required this.id,
    required this.dayId,
    required this.dayTitle,
    required this.date,
    required this.loggedAt,
    required this.loggedBy,
    required this.loggedByName,
    required this.exerciseCount,
    required this.setCount,
    required this.volume,
    required this.cycleCheck,
    required this.improved,
    required this.pr,
    required this.exercises,
    this.coachComment,
  });
  final String id;
  final String dayId;
  final String dayTitle;
  final String date;
  final String loggedAt;
  final String loggedBy;
  final String? loggedByName;
  final int exerciseCount;
  final int setCount;
  final double volume;
  final bool cycleCheck;
  final bool improved;
  final bool pr;
  final List<WorkoutHistoryExercise> exercises;
  final String? coachComment;

  String get who => loggedBy == "coach"
      ? (loggedByName != null && loggedByName!.trim().isNotEmpty ? loggedByName!.trim() : "Coach")
      : "Self";
}

int _completedSetCount(WorkoutLogEntry log) {
  var n = 0;
  for (final ex in log.exercises) {
    n = n + ex.sets.where((s) => s.completed).length;
  }
  return n;
}

String _sortKey(WorkoutLogEntry log) => log.loggedAt ?? log.date;

/// The id a live session uses for one program day on one date.
String liveWorkoutId(String date, String dayId) => "live-$date-$dayId";

/// Two saves of the same live session, or a thin save of the same day and
/// date, collapse into the fuller one. A later thin save does not hide a
/// full workout. Two different saved workouts stay separate.
List<WorkoutLogEntry> mergeDuplicateWorkoutLogs(List<WorkoutLogEntry> logs) {
  final kept = <WorkoutLogEntry>[];
  final ordered = [...logs]..sort((a, b) => _sortKey(b).compareTo(_sortKey(a)));
  for (final log in ordered) {
    final liveId = liveWorkoutId(log.date, log.dayId);
    final dup = kept.indexWhere((k) =>
        k.id == log.id ||
        (k.dayId == log.dayId && k.date == log.date && (k.id == liveId || log.id == liveId)));
    if (dup < 0) {
      kept.add(log);
      continue;
    }
    final other = kept[dup];
    final mine = _completedSetCount(log);
    final theirs = _completedSetCount(other);
    if (mine > theirs || (mine == theirs && _sortKey(log).compareTo(_sortKey(other)) > 0)) {
      kept[dup] = log;
    }
  }
  kept.sort((a, b) => _sortKey(b).compareTo(_sortKey(a)));
  return kept;
}

double _volumeOf(WorkoutLogEntry log) {
  var total = 0.0;
  for (final ex in log.exercises) {
    for (final s in ex.sets) {
      if (!s.completed) continue;
      total += (s.completedWeight ?? 0) * (s.completedReps ?? 0);
    }
  }
  return total;
}

/// Every saved workout, newest first, with the change from the previous
/// time that exercise and set were logged.
List<WorkoutHistoryCard> workoutHistory(ClientRecord client) {
  final merged = mergeDuplicateWorkoutLogs(client.workoutLogs);
  final chronological = [...merged]..sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));
  final programs = client.savedPrograms.where((p) => p.programDays.isNotEmpty).toList();
  final cycleByProgram = <String, Set<String>>{
    for (final p in programs) p.id: getCurrentCycleCompletedDays(client, p.programDays),
  };
  final newestOfDay = <String, String>{};
  for (final log in merged) {
    newestOfDay.putIfAbsent(log.dayId, () => log.id);
  }

  final cards = <WorkoutHistoryCard>[];
  for (var i = 0; i < chronological.length; i++) {
    final log = chronological[i];
    final earlier = chronological.take(i);
    final exercises = <WorkoutHistoryExercise>[];
    var improved = false;
    var pr = false;
    for (final ex in log.exercises) {
      final sets = <WorkoutHistorySet>[];
      for (final s in ex.sets.where((s) => s.completed)) {
        WorkoutHistorySet? prev;
        for (final old in earlier.toList().reversed) {
          final oldEx = old.exercises.where((e) => e.name == ex.name);
          if (oldEx.isEmpty) continue;
          final oldSet = oldEx.first.sets.where((os) => os.setNum == s.setNum && os.completed);
          if (oldSet.isEmpty) continue;
          prev = WorkoutHistorySet(
            setNum: s.setNum,
            reps: s.completedReps ?? 0,
            weight: s.completedWeight ?? 0,
            prevReps: oldSet.first.completedReps,
            prevWeight: oldSet.first.completedWeight,
          );
          break;
        }
        final line = prev ??
            WorkoutHistorySet(
              setNum: s.setNum,
              reps: s.completedReps ?? 0,
              weight: s.completedWeight ?? 0,
            );
        if (line.weightMark == "up" || line.repsMark == "up") improved = true;
        var best = 0.0;
        for (final old in earlier) {
          for (final oldEx in old.exercises.where((e) => e.name == ex.name)) {
            for (final os in oldEx.sets.where((os) => os.setNum == s.setNum && os.completed)) {
              final w = os.completedWeight ?? 0;
              if (w > best) best = w;
            }
          }
        }
        if (best > 0 && (s.completedWeight ?? 0) > best) pr = true;
        sets.add(line);
      }
      if (sets.isNotEmpty) exercises.add(WorkoutHistoryExercise(name: ex.name, sets: sets));
    }
    final setCount = exercises.fold<int>(0, (n, e) => n + e.sets.length);
    final cycle = cycleByProgram[log.programId] ?? const <String>{};
    cards.add(WorkoutHistoryCard(
      id: log.id,
      dayId: log.dayId,
      dayTitle: log.dayTitle,
      date: log.date,
      loggedAt: log.loggedAt ?? log.date,
      loggedBy: log.loggedBy,
      loggedByName: log.loggedByName,
      exerciseCount: exercises.length,
      setCount: setCount,
      volume: _volumeOf(log),
      cycleCheck: cycle.contains(log.dayId) && newestOfDay[log.dayId] == log.id,
      improved: improved,
      pr: pr,
      exercises: exercises,
      coachComment: log.coachComment,
    ));
  }
  cards.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
  return cards;
}
