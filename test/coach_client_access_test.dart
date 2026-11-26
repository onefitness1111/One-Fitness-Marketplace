import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/coach_merit_badge_utils.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/report_range.dart";
import "package:onefitness/data/models/trainer.dart";

void main() {
  test("check-in credit follows the coach on the session", () {
    const coach = Trainer(id: "chris", name: "Chris");
    const other = ClientInfo(id: "pat-client", name: "Pat Client");
    const range = ReportRange(preset: "month", start: "2026-11-01", end: "2026-11-30");
    const booking = Booking(
      id: "b1",
      clientId: "pat-client",
      trainerId: "chris",
      date: "2026-11-04",
      slot: 540,
      sessionType: "one-on-one",
      discipline: "strength",
      attendanceStatus: "no-show",
    );

    final progress = checkInBadge(coach, const [other], const <String, ClientRecord>{}, const [booking], range);

    expect(progress.target, 1);
    expect(progress.current, 0);
    expect(progress.detail, contains("0 of 1"));
  });
}
