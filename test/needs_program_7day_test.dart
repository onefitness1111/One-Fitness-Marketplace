import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/attention_utils.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/core/utils/intake_resubmit.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_record.dart";

// Sunday Nov 22 2026, 5:00 PM at the gym (PST, UTC-8).
final now = DateTime.utc(2026, 11, 23, 1, 0);

Booking b(String id, String client, String coach, String date, int slot,
        {String status = "confirmed", String? attendance, int duration = 60}) =>
    Booking(
      id: id,
      clientId: client,
      trainerId: coach,
      date: date,
      slot: slot,
      sessionType: "1on1",
      discipline: "strength",
      status: status,
      attendanceStatus: attendance,
      durationMin: duration,
    );

const roster = [
  ClientInfo(id: "c1", name: "A"),
  ClientInfo(id: "c2", name: "B"),
  ClientInfo(id: "c3", name: "C"),
  ClientInfo(id: "c4", name: "D"),
  ClientInfo(id: "c5", name: "E"),
  ClientInfo(id: "c6", name: "F"),
];

void main() {
  test("gym wall clock is Pacific whatever the phone's zone", () {
    expect(pacificWallNow(now), DateTime(2026, 11, 22, 17, 0));
    expect(isoTodayPacific(now), "2026-11-22");
    // Summer: UTC-7.
    expect(pacificWallNow(DateTime.utc(2026, 7, 1, 6, 30)), DateTime(2026, 6, 30, 23, 30));
  });

  final bookings = [
    b("1", "c1", "k1", "2026-11-23", 600), // tomorrow with k1: counts
    b("2", "c2", "k2", "2026-11-23", 600), // with another coach: not for k1
    b("3", "c3", "k1", "2026-11-29", 1020), // exactly 7 days out, 5:00 PM: counts
    b("4", "c4", "k1", "2026-11-29", 1080), // 7 days + 1 hour: too far
    b("5", "c5", "k1", "2026-11-24", 600, status: "cancelled"), // cancelled: no
    b("6", "c6", "k1", "2026-11-22", 900), // today 3-4 PM, already over: no
    b("7", "c6", "k1", "2026-11-21", 600), // past: no
  ];

  test("coach sees only clients booked with them in the next 7 days", () {
    expect(clientsBookedWithCoachSoon(bookings, "k1", now: now), {"c1", "c3"});
    expect(clientsBookedWithCoachSoon(bookings, "k2", now: now), {"c2"});
  });

  test("a session in progress still counts until it ends", () {
    final live = [b("8", "c6", "k1", "2026-11-22", 990)]; // 4:30-5:30 PM
    expect(clientsBookedWithCoachSoon(live, "k1", now: now), {"c6"});
  });

  test("late/early-cancel attendance marks don't count", () {
    final marked = [b("9", "c1", "k1", "2026-11-24", 600, attendance: "late-cancel")];
    expect(clientsBookedWithCoachSoon(marked, "k1", now: now), isEmpty);
  });

  test("owner keeps everyone; a coach with no bookings sees nobody", () {
    expect(needsProgramRoster(roster: roster, bookings: bookings, isOwner: true, coachId: "owner", now: now).length, 6);
    expect(needsProgramRoster(roster: roster, bookings: bookings, isOwner: false, coachId: "k9", now: now), isEmpty);
    expect(needsProgramRoster(roster: roster, bookings: bookings, isOwner: false, coachId: null, now: now), isEmpty);
  });

  test("Needs Attention rows and their counts follow the filtered list", () {
    final records = <String, ClientRecord>{};
    final mine = needsProgramRoster(roster: roster, bookings: bookings, isOwner: false, coachId: "k1", now: now);
    final items = computeNeedsAttention(mine, records);
    final noProgram = items.where((i) => i.key == "no-program").map((i) => i.clientId).toSet();
    final noNutrition = items.where((i) => i.key == "no-nutrition").map((i) => i.clientId).toSet();
    expect(noProgram, {"c1", "c3"});
    expect(noNutrition, {"c1", "c3"});
    expect(items.length, 4); // the "(N)" header counts come from these lists

    final ownerItems = computeNeedsAttention(
        needsProgramRoster(roster: roster, bookings: bookings, isOwner: true, coachId: "owner", now: now), records);
    expect(ownerItems.length, 12);
  });

  test("program-update rows use the same filter", () {
    final records = {
      for (final c in roster) c.id: ClientRecord(id: c.id, programRefresh: const {"training": "2026-11-22"}),
    };
    final mine = needsProgramRoster(roster: roster, bookings: bookings, isOwner: false, coachId: "k1", now: now);
    final items = programRefreshAttention(mine, records, forOwner: false);
    expect(items.map((i) => i.clientId).toSet(), {"c1", "c3"});
  });
}
