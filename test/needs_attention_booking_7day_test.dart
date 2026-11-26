import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/attention_utils.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";

// "Now" for the 7-day window. Kept after every past session below, which
// are dated before the real today so they count as unlogged.
final now = DateTime.utc(2027, 3, 1, 20, 0);

Booking b(String id, String client, String coach, String date, int slot, {String? attendance}) => Booking(
      id: id,
      clientId: client,
      trainerId: coach,
      date: date,
      slot: slot,
      sessionType: "1on1",
      discipline: "strength",
      status: "confirmed",
      attendanceStatus: attendance,
    );

/// C8: "No attendance logged" and "Coach Code" rows follow the 7-day rule
/// for a coach, like the program and quiet-client rows. The owner sees all.
void main() {
  const roster = [
    ClientInfo(id: "soon", name: "A", referredByTrainerId: "k1"),
    ClientInfo(id: "later", name: "B", referredByTrainerId: "k1"),
    ClientInfo(id: "other", name: "C", referredByTrainerId: "k2"),
  ];
  final bookings = [
    b("p1", "soon", "k1", "2026-11-20", 600), // past, unlogged, k1
    b("n1", "soon", "k1", "2027-03-03", 600), // booked with k1 in 7 days
    b("p2", "later", "k1", "2026-11-19", 600), // past, unlogged, k1, nothing soon
    b("n2", "later", "k1", "2027-04-15", 600), // too far out
    b("p3", "other", "k2", "2026-11-18", 600), // another coach's session
  ];

  test("a coach sees only clients booked with them in the next 7 days", () {
    final rows = bookingAttentionForViewer(roster: roster, bookings: bookings, isOwner: false, coachId: "k1", now: now);
    final unlogged = rows.where((r) => r.key == "no-attendance").map((r) => r.bookingId).toList();
    final code = rows.where((r) => r.key == "coach-code-used").map((r) => r.clientId).toList();
    expect(unlogged, ["p1"]);
    expect(code, ["soon"]);
  });

  test("a coach never sees another coach's code signups", () {
    final rows = bookingAttentionForViewer(roster: roster, bookings: bookings, isOwner: false, coachId: "k2", now: now);
    expect(rows.where((r) => r.key == "coach-code-used"), isEmpty);
    // k2 has no session in the next 7 days, so nothing at all.
    expect(rows, isEmpty);
  });

  test("the owner sees everyone", () {
    final rows = bookingAttentionForViewer(roster: roster, bookings: bookings, isOwner: true, coachId: "owner", now: now);
    expect(rows.where((r) => r.key == "no-attendance").map((r) => r.bookingId).toSet(), {"p1", "p2", "p3"});
    expect(rows.where((r) => r.key == "coach-code-used").map((r) => r.clientId).toSet(), {"soon", "later", "other"});
  });
}
