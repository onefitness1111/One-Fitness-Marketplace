import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/data/models/live_session.dart";
import "package:onefitness/data/providers/beep_providers.dart";
import "package:onefitness/features/client/beep/client_live_session_layer.dart";

Map<String, dynamic> run({
  required String client,
  required String day,
  required String date,
  String role = "coach",
  String? trainer,
}) =>
    {
      "client_id": client,
      "day_id": day,
      "log_date": date,
      "started_role": role,
      "trainer_id": trainer,
    };

Map<String, dynamic> marker({
  required String client,
  required String day,
  required String date,
}) =>
    {
      "client_id": client,
      "day_id": day,
      "log_date": date,
      "exercise_name": "__day_started_coach__",
    };

void main() {
  const today = "2026-11-22";
  const yesterday = "2026-11-21";

  test("an open coach run still shows on the client bar", () {
    final days = coachLedDaysFromRows(
      openRuns: [run(client: "violet", day: "day-1", date: today, trainer: "coach-1")],
      openCoachMarkers: const [],
      todayPacific: today,
    );
    expect(days, hasLength(1));
    expect(days.single.clientId, "violet");
    expect(days.single.dayId, "day-1");
    expect(days.single.trainerId, "coach-1");
  });

  test("a leftover coach marker does not show once its live-day run is closed", () {
    final days = coachLedDaysFromRows(
      openRuns: const [],
      openCoachMarkers: [marker(client: "violet", day: "day-1", date: today)],
      todayPacific: today,
    );
    expect(days, isEmpty);
  });

  test("a coach marker from before today Pacific cannot show the bar", () {
    final days = coachLedDaysFromRows(
      openRuns: [run(client: "violet", day: "day-1", date: yesterday, trainer: "coach-1")],
      openCoachMarkers: [marker(client: "violet", day: "day-1", date: yesterday)],
      todayPacific: today,
    );
    // The open run is still coach-led, so the bar follows the run.
    expect(days.single.dayId, "day-1");

    final markerOnly = coachLedDaysFromRows(
      openRuns: [run(client: "violet", day: "day-1", date: yesterday, role: "client")],
      openCoachMarkers: [marker(client: "violet", day: "day-1", date: yesterday)],
      todayPacific: today,
    );
    expect(markerOnly, isEmpty);
  });

  test("today's coach marker counts only when the matching run is still open", () {
    final withClientRun = coachLedDaysFromRows(
      openRuns: [run(client: "violet", day: "day-1", date: today, role: "client")],
      openCoachMarkers: [marker(client: "violet", day: "day-1", date: today)],
      todayPacific: today,
    );
    expect(withClientRun, hasLength(1));
    expect(withClientRun.single.dayId, "day-1");

    final wrongDay = coachLedDaysFromRows(
      openRuns: [run(client: "violet", day: "day-2", date: today, role: "client")],
      openCoachMarkers: [marker(client: "violet", day: "day-1", date: today)],
      todayPacific: today,
    );
    expect(wrongDay, isEmpty);
  });

  test("a client-only run without a coach marker does not show the bar", () {
    final days = coachLedDaysFromRows(
      openRuns: [run(client: "violet", day: "day-1", date: today, role: "client")],
      openCoachMarkers: const [],
      todayPacific: today,
    );
    expect(days, isEmpty);
  });

  test("isoTodayPacific uses the America/Los_Angeles calendar day", () {
    // 11:30 PM on Nov 21 Pacific is already Nov 22 UTC.
    expect(isoTodayPacific(DateTime.utc(2026, 11, 22, 7, 30)), "2026-11-21");
    expect(isoTodayPacific(DateTime.utc(2026, 11, 22, 8)), "2026-11-22");
  });

  test("the pinned bar shows a label when Beep Your Coach would be empty", () {
    const led = CoachLedDay(clientId: "violet", dayId: "day-1");
    expect(coachLiveBarShowsBeep(led, null), isFalse);
    expect(coachStartedWorkoutLabel, "Your coach started your workout");

    const withTrainer = CoachLedDay(clientId: "violet", dayId: "day-1", trainerId: "coach-1");
    expect(coachLiveBarShowsBeep(withTrainer, null), isTrue);

    final booked = LiveSession(
      id: "run-1",
      trainerId: "coach-1",
      date: today,
      slotMin: 0,
      sessionType: "semi-private",
      startedAt: "2026-11-22T18:00:00Z",
    );
    expect(coachLiveBarShowsBeep(led, booked), isTrue);
  });

  test("the live bar reloads when live_day_runs change, and end closes start markers", () {
    final beep = File("lib/data/providers/beep_providers.dart").readAsStringSync();
    expect(beep.contains('table: "live_set_logs"'), isTrue);
    expect(beep.contains('table: "live_day_runs"'), isTrue);
    final sync = File("lib/core/live_log/live_log_sync.dart").readAsStringSync();
    expect(sync.contains("closeOpenStartMarkers"), isTrue);
    expect(sync.contains("liveDayStartMarkers"), isTrue);
  });
}
