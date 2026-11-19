/// Mirrors one set entry inside a logged exercise (ExerciseSetGrid.jsx /
/// programHelpers.js `sets`).
class LoggedSet {
  const LoggedSet({
    required this.setNum,
    this.targetReps = 0,
    this.completedReps,
    this.completedWeight,
    this.completed = false,
  });

  final int setNum;
  final int targetReps;
  final int? completedReps;
  final double? completedWeight;
  final bool completed;
}

/// One exercise's logged sets within a WorkoutLogEntry.
class LoggedExercise {
  const LoggedExercise({required this.name, this.sets = const []});

  final String name;
  final List<LoggedSet> sets;
}

/// Mirrors one entry in `client.workoutLogs` — a completed logged session.
class WorkoutLogEntry {
  const WorkoutLogEntry({
    required this.id,
    required this.date,
    required this.programId,
    required this.programName,
    required this.dayId,
    required this.dayTitle,
    this.exercises = const [],
    this.loggedAt,
    this.loggedBy = "client",
    this.loggedByName,
  this.coachComment,
  this.coachCommentAt,
  this.swaps = const [],
});

  final String id;
  final String date; // ISO yyyy-MM-dd
  final String programId;
  final String programName;
  final String dayId;
  final String dayTitle;
  final List<LoggedExercise> exercises;
  final String? loggedAt; // ISO datetime, used to order same-day sessions

  /// "client" (self-logged) | "coach" (logged on the client's behalf via
  /// the coach's own Start Session flow) — see SessionLoggerView.
  final String loggedBy;

  /// Public coach name when [loggedBy] is "coach". Never a legal name.
  final String? loggedByName;

  /// A coach's note left on this specific session (Notifications spec —
  /// "Coach comments on a workout"), shown to the client and emailed once
  /// on save. One comment per session, editable — not a full thread.
  final String? coachComment;
  final String? coachCommentAt;

  /// Equipment swaps for this session only. The program itself is unchanged.
  final List<LoggedSwap> swaps;

  WorkoutLogEntry copyWith({String? coachComment, String? coachCommentAt, List<LoggedSwap>? swaps}) => WorkoutLogEntry(
        id: id,
        date: date,
        programId: programId,
        programName: programName,
        dayId: dayId,
        dayTitle: dayTitle,
        exercises: exercises,
        loggedAt: loggedAt,
        loggedBy: loggedBy,
        loggedByName: loggedByName,
        coachComment: coachComment ?? this.coachComment,
        coachCommentAt: coachCommentAt ?? this.coachCommentAt,
        swaps: swaps ?? this.swaps,
      );
}

/// One exercise swapped for another during a single workout.
class LoggedSwap {
  const LoggedSwap({required this.fromName, required this.toName, required this.muscle});

  final String fromName;
  final String toName;
  final String muscle;
}
