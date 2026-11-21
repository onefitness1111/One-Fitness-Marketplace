import "../../data/models/exercise_def.dart";
import "../../data/models/workout_log.dart";
import "notification_triggers.dart";

/// The last time this client logged this exercise, one set at a time.
///
/// Only [logs] are read. Pass that client's own history. A different
/// exercise, or a set they have never finished, is left empty.
class LastPerformance {
  const LastPerformance({this.reps, this.weight});
  final int? reps;
  final double? weight;
}

LastPerformance? lastTimeFor(List<WorkoutLogEntry> logs, String exerciseName, int setNum) {
  final name = exerciseName.trim().toLowerCase();
  if (name.isEmpty) return null;
  final sorted = [...logs]..sort(_newestFirst);
  for (final log in sorted) {
    final matches = log.exercises.where((e) => e.name.trim().toLowerCase() == name);
    if (matches.isEmpty) continue;
    final sets = matches.first.sets.where((s) => s.setNum == setNum && s.completed);
    if (sets.isEmpty) continue;
    final set = sets.first;
    if (set.completedReps == null && (set.completedWeight == null || set.completedWeight == 0)) {
      continue;
    }
    return LastPerformance(reps: set.completedReps, weight: set.completedWeight);
  }
  return null;
}

/// Other exercises that work the same muscle. The current exercise is left out.
List<ExerciseDef> sameMuscleAlternatives(List<ExerciseDef> catalog, {required String? exerciseId, required String name, required String muscle}) {
  final group = muscle.trim().toLowerCase();
  if (group.isEmpty) return const [];
  final currentName = name.trim().toLowerCase();
  return [
    for (final item in catalog)
      if (item.id != exerciseId &&
          item.primaryMuscle.trim().toLowerCase() == group &&
          item.name.trim().toLowerCase() != currentName)
        item,
  ];
}

class WorkoutSummary {
  const WorkoutSummary({
    required this.volume,
    required this.prs,
    required this.streakDays,
  });

  /// Reps times weight, across every finished set.
  final double volume;
  final List<String> prs;
  final int streakDays;
}

WorkoutSummary workoutSummary({
  required WorkoutLogEntry session,
  required List<WorkoutLogEntry> earlierLogs,
}) {
  return WorkoutSummary(
    volume: sessionVolume(session),
    prs: sessionPrs(session, earlierLogs),
    streakDays: workoutStreakDays([...earlierLogs, session], session.date),
  );
}

double sessionVolume(WorkoutLogEntry session) {
  var total = 0.0;
  for (final exercise in session.exercises) {
    for (final set in exercise.sets) {
      final reps = set.completedReps ?? 0;
      final weight = set.completedWeight ?? 0;
      if (reps > 0 && weight > 0) total += reps * weight;
    }
  }
  return total;
}

/// A heavier weight than this client has logged for that exercise before.
List<String> sessionPrs(WorkoutLogEntry session, List<WorkoutLogEntry> earlierLogs) {
  final names = <String>[];
  for (final exercise in session.exercises) {
    final bestNow = _bestWeight(exercise.sets);
    if (bestNow == null || bestNow <= 0) continue;
    final prior = _bestEver(earlierLogs, exercise.name);
    if (prior != null && bestNow > prior) names.add(exercise.name);
  }
  return names;
}

/// Days in a row with a workout, ending on [today] (yyyy-MM-dd).
int workoutStreakDays(List<WorkoutLogEntry> logs, String today) {
  final days = <String>{};
  for (final log in logs) {
    if (_didWork(log)) days.add(log.date);
  }
  if (!days.contains(today)) return 0;
  final parsed = DateTime.tryParse(today);
  if (parsed == null) return 0;
  var streak = 0;
  var day = parsed;
  while (days.contains(_ymd(day))) {
    streak++;
    day = day.subtract(const Duration(days: 1));
  }
  return streak;
}

/// The heaviest weight logged for [exerciseName], oldest session first.
List<double> liftTrend(List<WorkoutLogEntry> logs, String exerciseName, {int limit = 8}) {
  final name = exerciseName.trim().toLowerCase();
  final points = <double>[];
  final sorted = [...logs]..sort((a, b) => _newestFirst(b, a));
  for (final log in sorted) {
    final matches = log.exercises.where((e) => e.name.trim().toLowerCase() == name);
    if (matches.isEmpty) continue;
    final best = _bestWeight(matches.first.sets);
    if (best != null && best > 0) points.add(best);
  }
  if (points.length <= limit) return points;
  return points.sublist(points.length - limit);
}

bool _didWork(WorkoutLogEntry log) {
  for (final exercise in log.exercises) {
    for (final set in exercise.sets) {
      if (set.completed || (set.completedReps ?? 0) > 0 || (set.completedWeight ?? 0) > 0) {
        return true;
      }
    }
  }
  return false;
}

double? _bestWeight(List<LoggedSet> sets) {
  double? best;
  for (final set in sets) {
    final weight = set.completedWeight;
    if (weight == null || weight <= 0) continue;
    if (best == null || weight > best) best = weight;
  }
  return best;
}

double? bestLoggedWeightNamed(List<WorkoutLogEntry> logs, String exerciseName) => _bestEver(logs, exerciseName);

double? _bestEver(List<WorkoutLogEntry> logs, String exerciseName) {
  final name = exerciseName.trim().toLowerCase();
  double? best;
  for (final log in logs) {
    for (final exercise in log.exercises) {
      if (exercise.name.trim().toLowerCase() != name) continue;
      final weight = _bestWeight(exercise.sets);
      if (weight != null && (best == null || weight > best)) best = weight;
    }
  }
  return best;
}

int _newestFirst(WorkoutLogEntry a, WorkoutLogEntry b) {
  final byDate = b.date.compareTo(a.date);
  if (byDate != 0) return byDate;
  return (b.loggedAt ?? "").compareTo(a.loggedAt ?? "");
}

/// Tells every coach that today's session used different equipment.
/// There is no assigned coach to single out. The program itself is not changed.
void flagSessionSwaps({
  required WorkoutLogEntry entry,
  required String clientName,
}) {
  if (entry.swaps.isEmpty) return;
  final detail = entry.swaps.map((swap) => "${swap.fromName} for ${swap.toName}").join(", ");
  final body = "$clientName swapped $detail today. The program was not changed.";
  notifyAllCoaches(title: "Exercise swap", body: body);
}

String _ymd(DateTime day) {
  final y = day.year.toString().padLeft(4, "0");
  final m = day.month.toString().padLeft(2, "0");
  final d = day.day.toString().padLeft(2, "0");
  return "$y-$m-$d";
}
