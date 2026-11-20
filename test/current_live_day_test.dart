import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/live_log/current_live_day.dart";

LiveDayRun run(String client, String day, DateTime at, {DateTime? ended}) =>
    LiveDayRun(clientId: client, dayId: day, startedAt: at, endedAt: ended);

void main() {
  final earlier = DateTime.utc(2026, 11, 20, 16);
  final later = earlier.add(const Duration(minutes: 20));

  test("two open days show only the newest, and an unfinished log is not a badge", () {
    final badges = currentLiveDayByClient([
      run("violet", "day-1", earlier),
      run("violet", "day-2", later),
      run("sam", "day-1", earlier, ended: later),
    ]);
    expect(badges, {"violet": "day-2"});
    expect(badges.containsKey("sam"), isFalse);
  });

  test("starting another day ends the previous live day and leaves one open", () {
    final next = replaceLiveDay(
      openRuns: [run("violet", "day-1", earlier)],
      clientId: "violet",
      dayId: "day-2",
      at: later,
    );
    expect(currentLiveDayByClient(next), {"violet": "day-2"});
    expect(next.where((r) => r.dayId == "day-1").single.isOpen, isFalse);
  });

  test("ending the live session clears every live badge and does not invent a lock", () {
    final next = endLiveDays(
      [run("violet", "day-1", earlier), run("violet", "day-2", later)],
      clientId: "violet",
      at: later.add(const Duration(minutes: 5)),
    );
    expect(currentLiveDayByClient(next), isEmpty);
    expect(next.every((r) => !r.isOpen), isTrue);
  });
}
