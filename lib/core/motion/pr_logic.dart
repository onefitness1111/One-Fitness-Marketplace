/// A weight beats the client's previous best for that exercise.
///
/// The first time an exercise is logged there is no previous best, so it
/// is not a PR. Clearing the number, or typing a lower one, is not a PR.
bool weightIsPersonalRecord({required double? previousBest, required double? weight}) {
  if (weight == null || weight <= 0) return false;
  if (previousBest == null || previousBest <= 0) return false;
  return weight > previousBest;
}

/// Same exercise and set at the same weight should celebrate once.
/// A later edit that is still a record celebrates again.
bool shouldCelebratePr({
  required double? previousBest,
  required double? weight,
  required double? lastCelebrated,
  required bool appInForeground,
}) {
  if (!appInForeground) return false;
  if (!weightIsPersonalRecord(previousBest: previousBest, weight: weight)) return false;
  if (lastCelebrated != null && lastCelebrated == weight) return false;
  return true;
}
