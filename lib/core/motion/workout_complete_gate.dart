class LoggedWorkout {
  const LoggedWorkout({required this.id, required this.loggedAt, required this.didWork});

  final String id;
  final String loggedAt;
  final bool didWork;
}

class WorkoutCompleteDecision {
  const WorkoutCompleteDecision({required this.showId, required this.seen, required this.seeded});

  /// Null when nothing should be shown.
  final String? showId;

  /// The seen list to store. Includes a first-run seed of every existing id.
  final List<String> seen;
  final bool seeded;
}

/// The next time the client opens the app, show the newest finished workout
/// they have not tapped Done on. The first time this runs, existing workouts
/// are marked seen so old history does not replay.
WorkoutCompleteDecision nextWorkoutComplete({
  required List<LoggedWorkout> logs,
  required List<String>? storedSeen,
}) {
  final worked = logs.where((l) => l.didWork && l.id.isNotEmpty).toList();
  if (storedSeen == null) {
    return WorkoutCompleteDecision(
      showId: null,
      seen: worked.map((l) => l.id).toList(),
      seeded: true,
    );
  }
  final seen = storedSeen.toSet();
  final pending = worked.where((l) => !seen.contains(l.id)).toList()
    ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
  return WorkoutCompleteDecision(
    showId: pending.isEmpty ? null : pending.first.id,
    seen: storedSeen,
    seeded: false,
  );
}
