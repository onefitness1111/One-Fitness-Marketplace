import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/notification_matrix.dart";
import "package:onefitness/core/utils/program_utils.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/program_day.dart";
import "package:onefitness/data/models/saved_program.dart";
import "package:onefitness/data/models/workout_log.dart";

WorkoutLogEntry log({
  required String id,
  required String dayId,
  required String date,
  required String loggedAt,
  required int sets,
  double weight = 100,
  int reps = 10,
  String loggedBy = "client",
  String? loggedByName,
}) {
  return WorkoutLogEntry(
    id: id,
    date: date,
    programId: "prog",
    programName: "Strength",
    dayId: dayId,
    dayTitle: dayId == "d1" ? "Day 1" : "Day 2",
    loggedAt: loggedAt,
    loggedBy: loggedBy,
    loggedByName: loggedByName,
    exercises: [
      LoggedExercise(
        name: "Bench",
        sets: [
          for (var i = 1; i <= sets; i++)
            LoggedSet(
              setNum: i,
              completed: true,
              completedWeight: weight,
              completedReps: reps,
            ),
        ],
      ),
    ],
  );
}

void main() {
  test("a thinner same-day save does not hide the full workout", () {
    final full = log(id: "live-2026-11-18-d1", dayId: "d1", date: "2026-11-18", loggedAt: "2026-11-18T10:00:00", sets: 4, weight: 20, reps: 10);
    final thin = log(id: "other", dayId: "d1", date: "2026-11-18", loggedAt: "2026-11-18T10:05:00", sets: 1, weight: 2, reps: 1);
    final merged = mergeDuplicateWorkoutLogs([thin, full]);
    expect(merged, hasLength(1));
    expect(merged.first.id, full.id);
    expect(merged.first.exercises.first.sets, hasLength(4));
  });

  test("two different days on the same date both stay", () {
    final a = log(id: "a", dayId: "d1", date: "2026-11-18", loggedAt: "2026-11-18T09:00:00", sets: 3);
    final b = log(id: "b", dayId: "d2", date: "2026-11-18", loggedAt: "2026-11-18T18:00:00", sets: 3);
    final cards = workoutHistory(ClientRecord(
      id: "c",
      workoutLogs: [a, b],
      savedPrograms: [
        SavedProgram(
          id: "prog",
          name: "Strength",
          status: "active",
          programDays: const [
            ProgramDay(id: "d1", title: "Day 1"),
            ProgramDay(id: "d2", title: "Day 2"),
          ],
        ),
      ],
    ));
    expect(cards, hasLength(2));
    expect(cards.first.dayId, "d2");
    expect(cards.first.exerciseCount, 1);
    expect(cards.first.setCount, 3);
    expect(cards.first.volume, 3000);
    expect(cards.first.who, "Self");
  });

  test("a heavier set is a PR and shows the weight change", () {
    final first = log(id: "1", dayId: "d1", date: "2026-11-01", loggedAt: "2026-11-01T10:00:00", sets: 1, weight: 100, reps: 8);
    final second = log(id: "2", dayId: "d1", date: "2026-11-08", loggedAt: "2026-11-08T10:00:00", sets: 1, weight: 110, reps: 10, loggedBy: "coach", loggedByName: "Coach Chris");
    final cards = workoutHistory(ClientRecord(id: "c", workoutLogs: [first, second]));
    final newer = cards.first;
    expect(newer.who, "Coach Chris");
    expect(newer.pr, isTrue);
    expect(newer.exercises.first.sets.first.weightMark, "up");
    expect(newer.exercises.first.sets.first.repsMark, "up");
    expect(newer.exercises.first.sets.first.prevWeight, 100);
  });

  test("a session notifies the coach who ran it, and a sign-up notifies every coach", () {
    const hollywood = CoachAudience(id: "kajer", location: "Hollywood", publicName: "Coach Kajer");
    const westwood = CoachAudience(id: "paul", location: "Westwood", publicName: "Coach Paul");
    final heard = audienceFor(
      clientId: "client",
      coaches: const [hollywood, westwood],
      ownerIds: const ["owner"],
      eventTrainerId: "paul",
    );
    expect(heard.coachIds, ["paul"]);
    expect(heard.clientIds, ["client"]);
    expect(heard.ownerIds, isEmpty);

    final signup = audienceFor(
      clientId: "client",
      coaches: const [hollywood, westwood],
      ownerIds: const ["owner"],
    );
    expect(signup.coachIds, ["kajer", "paul"]);

    final internal = audienceFor(
      clientId: "client",
      coaches: const [hollywood, westwood],
      ownerIds: const ["owner"],
      internal: true,
    );
    expect(internal.coachIds, isEmpty);
    expect(internal.ownerIds, ["owner"]);
    expect(coachLabel(hollywood), "Coach Kajer");
  });
}
