import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/workout_week.dart";
import "package:onefitness/data/models/program_day.dart";

void main() {
  test("the week starts Monday and days repeat in order", () {
    final monday = DateTime(2026, 5, 18);
    expect(weekStart(monday.add(const Duration(days: 3))), monday);
    final days = [
      const ProgramDay(id: "push", title: "Push"),
      const ProgramDay(id: "pull", title: "Pull"),
    ];
    expect(programDayOn(days, monday)!.title, "Push");
    expect(programDayOn(days, monday.add(const Duration(days: 1)))!.title, "Pull");
    expect(programDayOn(days, monday.add(const Duration(days: 2)))!.title, "Push");
  });
}
