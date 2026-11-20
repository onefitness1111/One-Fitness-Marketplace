import "../../data/models/workout_log.dart";

/// Day ids checked in the current round of [programDayIds].
///
/// Walks [logs] from oldest to newest. A log counts only when its day is in
/// the program and that day is not already checked this round. Logging the
/// last unchecked day finishes the round, so every check clears and the next
/// log starts again from nothing. Logs for any other day are ignored.
Set<String> currentCycleCheckedDays({
  required List<String> programDayIds,
  required List<WorkoutLogEntry> logs,
}) {
  final dayIds = programDayIds.toSet();
  if (dayIds.isEmpty) return const <String>{};

  final ordered = <({String dayId, String when, int index})>[];
  for (var i = 0; i < logs.length; i++) {
    final log = logs[i];
    if (!dayIds.contains(log.dayId)) continue;
    final at = log.loggedAt;
    ordered.add((
      dayId: log.dayId,
      when: (at != null && at.isNotEmpty) ? at : log.date,
      index: i,
    ));
  }
  ordered.sort((a, b) {
    final byTime = a.when.compareTo(b.when);
    return byTime != 0 ? byTime : a.index.compareTo(b.index);
  });

  final done = <String>{};
  for (final log in ordered) {
    // A second log of a day already checked this round changes nothing.
    if (done.contains(log.dayId)) continue;
    done.add(log.dayId);
    if (done.length == dayIds.length) done.clear();
  }
  return done;
}
