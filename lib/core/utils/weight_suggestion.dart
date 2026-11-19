import "../../data/models/workout_log.dart";

/// How the next weight is rounded. Barbells and machines move in 5 lb
/// steps. Dumbbells move in 5 lb steps too, except under 25 lb, where the
/// smaller 2.5 lb bells are the step.
enum PlateKind { barbell, dumbbell, machine }

/// Reads the equipment list on an exercise. An unknown piece of equipment
/// uses the 5 lb step, the same step as a barbell or a machine.
PlateKind plateKindFor(Iterable<String> equipment) {
  final names = equipment.map((e) => e.toLowerCase());
  bool has(String word) => names.any((name) => name.contains(word));
  if (has("dumbbell")) return PlateKind.dumbbell;
  if (has("machine") || has("cable")) return PlateKind.machine;
  return PlateKind.barbell;
}

/// The first number in a prescribed weight such as "135" or "135 lbs".
double? parseTargetWeight(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r"\d+(?:\.\d+)?").firstMatch(raw.trim());
  if (match == null) return null;
  final value = double.tryParse(match.group(0)!);
  if (value == null || value <= 0) return null;
  return value;
}

/// The next load to suggest, or null when [currentLb] is not a real weight.
///
/// The suggestion is the smallest equipment step that is at least one full
/// step heavier and at least 2.5% heavier. When one step is already more
/// than 5%, that one step is still the suggestion. A smaller jump is never
/// offered.
double? nextWorkingWeight(double currentLb, PlateKind kind) {
  if (currentLb <= 0) return null;
  final needed = (currentLb * 1025).round();
  var cursor = (currentLb * 2).round();
  final start = cursor;
  for (var guard = 0; guard < 24; guard++) {
    final step = _stepUnits(kind, cursor);
    final next = _nextStep(cursor, step);
    if (next <= start) return null;
    final nextLb = next / 2.0;
    if ((nextLb * 1000).round() >= needed) return nextLb;
    cursor = next;
  }
  return null;
}

/// A client who hits every target rep at the working weight for this
/// exercise, two sessions in a row, gets one suggestion. A miss on the
/// latest session, or the one just before it, clears the streak. Other
/// exercises are left alone. The program itself is never changed.
double? suggestWeightIncrease({
  required List<WorkoutLogEntry> logs,
  required String exerciseName,
  required int targetReps,
  double? targetWeight,
  required PlateKind kind,
}) {
  final name = exerciseName.trim().toLowerCase();
  if (name.isEmpty) return null;
  final attempts = <List<LoggedSet>>[];
  final sorted = [...logs]..sort(_byTime);
  for (final log in sorted) {
    final matches = log.exercises.where(
      (e) => e.name.trim().toLowerCase() == name,
    );
    if (matches.isEmpty) continue;
    attempts.add(matches.first.sets);
  }
  if (attempts.length < 2) return null;
  final prior = attempts[attempts.length - 2];
  final latest = attempts[attempts.length - 1];
  if (!_hit(prior, targetReps, targetWeight) ||
      !_hit(latest, targetReps, targetWeight)) {
    return null;
  }
  final priorMin = _minWeight(prior);
  final latestMin = _minWeight(latest);
  if (priorMin == null || latestMin == null) return null;
  final repeated = priorMin < latestMin ? priorMin : latestMin;
  if (targetWeight != null && repeated + 0.001 < targetWeight) return null;
  final next = nextWorkingWeight(repeated, kind);
  if (next == null) return null;
  if ((next * 1000).round() <= (latestMin * 1000).round()) return null;
  return next;
}

int _stepUnits(PlateKind kind, int currentUnits) {
  if (kind == PlateKind.dumbbell && currentUnits < 50) return 5;
  return 10;
}

int _nextStep(int current, int step) {
  final remainder = current % step;
  if (remainder == 0) return current + step;
  return current + (step - remainder);
}

bool _hit(List<LoggedSet> sets, int fallbackReps, double? targetWeight) {
  if (sets.isEmpty) return false;
  for (final set in sets) {
    final goal = set.targetReps > 0 ? set.targetReps : fallbackReps;
    if (goal <= 0) return false;
    final reps = set.completedReps;
    if (reps == null || reps < goal) return false;
    final weight = set.completedWeight;
    if (weight == null || weight <= 0) return false;
    if (targetWeight != null && weight + 0.001 < targetWeight) return false;
  }
  return true;
}

double? _minWeight(List<LoggedSet> sets) {
  double? min;
  for (final set in sets) {
    final weight = set.completedWeight;
    if (weight == null || weight <= 0) return null;
    if (min == null || weight < min) min = weight;
  }
  return min;
}

int _byTime(WorkoutLogEntry a, WorkoutLogEntry b) {
  final byStamp = (a.loggedAt ?? a.date).compareTo(b.loggedAt ?? b.date);
  if (byStamp != 0) return byStamp;
  return a.date.compareTo(b.date);
}
