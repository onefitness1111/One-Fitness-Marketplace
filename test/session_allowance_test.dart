import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/membership_utils.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/membership_plan.dart";

void main() {
  final info = ClientInfo(id: "c1", name: "Eric");
  final plan = MembershipPlan(
    id: "pack",
    name: "8 pack",
    kind: PlanKind.package,
    maxSessions: 8,
    allowedTypes: const ["semi-private"],
  );

  Booking book(String id, {String? attendance}) => Booking(
        id: id,
        clientId: "c1",
        trainerId: "t1",
        date: "2026-11-18",
        slot: 540,
        sessionType: "semi-private",
        discipline: "strength",
        planId: "pack",
        attendanceStatus: attendance,
      );

  test("booking does not use a session, check-in and no-show do", () {
    final bookings = [
      book("future"),
      book("in", attendance: "checked-in"),
      book("miss", attendance: "no-show"),
    ];
    expect(sessionsUsedThisPeriod(info, plan, bookings), 2);
    expect(sessionsRemainingBalance(info, plan, bookings), 6);
    expect(sessionsTowardBookingLimit(info, plan, bookings), 3);
    expect(sessionsLeftToBook(info, plan, bookings), 5);
  });

  test("early and late cancels give the session back immediately", () {
    final bookings = [
      book("early", attendance: "early-cancel"),
      book("late", attendance: "late-cancel"),
      book("future"),
    ];
    expect(sessionsUsedThisPeriod(info, plan, bookings), 0);
    expect(sessionsTowardBookingLimit(info, plan, bookings), 1);
    expect(sessionsRemainingBalance(info, plan, bookings), 8);
    expect(sessionsLeftToBook(info, plan, bookings), 7);
  });

  test("a checked-in session is not counted twice", () {
    final bookings = [book("in", attendance: "checked-in")];
    expect(sessionsUsedThisPeriod(info, plan, bookings), 1);
    expect(sessionsTowardBookingLimit(info, plan, bookings), 1);
  });

  test("another client's booking does not count", () {
    final other = Booking(
      id: "x",
      clientId: "someone-else",
      trainerId: "t1",
      date: "2026-11-18",
      slot: 540,
      sessionType: "semi-private",
      discipline: "strength",
      planId: "pack",
      attendanceStatus: "checked-in",
    );
    expect(sessionsUsedThisPeriod(info, plan, [other]), 0);
    expect(sessionsLeftToBook(info, plan, [other]), 8);
  });
}
