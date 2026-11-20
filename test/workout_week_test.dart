import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/workout_week.dart";
import "package:onefitness/data/models/workout_log.dart";

WorkoutLogEntry _log(
  String dayId,
  String loggedAt, {
  String programId = "split",
}) {
  return WorkoutLogEntry(
    id: "$programId-$dayId-$loggedAt",
    date: loggedAt.length >= 10 ? loggedAt.substring(0, 10) : loggedAt,
    loggedAt: loggedAt,
    programId: programId,
    programName: programId,
    dayId: dayId,
    dayTitle: dayId,
  );
}

void main() {
  const split = ["push", "pull", "legs", "upper"];

  test("a 4-day split checks the days logged so far", () {
    // Listed out of time order, and not in program order either.
    final logs = [
      _log("legs", "2026-05-03T08:00:00"),
      _log("push", "2026-05-01T08:00:00"),
      _log("pull", "2026-05-02T08:00:00"),
    ];
    expect(currentCycleCheckedDays(programDayIds: split, logs: logs), {
      "push",
      "pull",
      "legs",
    });
  });

  test("repeating a checked day does not add a check or finish the round", () {
    final logs = [
      _log("push", "2026-05-01T08:00:00"),
      _log("push", "2026-05-01T18:00:00"),
      _log("pull", "2026-05-02T08:00:00"),
      _log("legs", "2026-05-03T08:00:00"),
      _log("push", "2026-05-04T08:00:00"),
    ];
    expect(currentCycleCheckedDays(programDayIds: split, logs: logs), {
      "push",
      "pull",
      "legs",
    });
  });

  test("logging the last unchecked day clears the round", () {
    // Newest first, the way a log list is often stored. Time order is
    // push, pull, legs, upper — that last one closes the round.
    final done = [
      _log("upper", "2026-05-04T08:00:00"),
      _log("legs", "2026-05-03T08:00:00"),
      _log("pull", "2026-05-02T08:00:00"),
      _log("push", "2026-05-01T08:00:00"),
    ];
    expect(currentCycleCheckedDays(programDayIds: split, logs: done), isEmpty);

    // The next log is a new round, not a leftover check from the old one.
    expect(
      currentCycleCheckedDays(
        programDayIds: split,
        logs: [...done, _log("legs", "2026-05-05T08:00:00")],
      ),
      {"legs"},
    );
  });

  test("a repeat after the round closes starts the next round", () {
    // Bench then squat finishes the round. The later squat is a new round.
    // Walking the list as stored (newest first) would clear that check.
    final logs = [
      _log("squat", "2026-05-03T09:00:00"),
      _log("squat", "2026-05-02T09:00:00"),
      _log("bench", "2026-05-01T09:00:00"),
    ];
    expect(
      currentCycleCheckedDays(
        programDayIds: const ["bench", "squat"],
        logs: logs,
      ),
      {"squat"},
    );
  });

  test("logs from other programs are ignored", () {
    final logs = [
      _log("push", "2026-05-01T08:00:00"),
      _log("old-a", "2026-05-02T08:00:00", programId: "previous"),
      _log("old-b", "2026-05-03T08:00:00", programId: "previous"),
      _log("old-c", "2026-05-04T08:00:00", programId: "previous"),
      _log("old-d", "2026-05-05T08:00:00", programId: "previous"),
      _log("pull", "2026-05-06T08:00:00"),
    ];
    expect(currentCycleCheckedDays(programDayIds: split, logs: logs), {
      "push",
      "pull",
    });
  });

  test("an empty log list or an empty program is a new round", () {
    expect(
      currentCycleCheckedDays(programDayIds: split, logs: const []),
      isEmpty,
    );
    expect(
      currentCycleCheckedDays(
        programDayIds: const [],
        logs: [_log("push", "2026-05-01T08:00:00")],
      ),
      isEmpty,
    );
  });
}
