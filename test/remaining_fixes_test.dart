import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/booking_pitch.dart";
import "package:onefitness/core/utils/booking_utils.dart";
import "package:onefitness/core/utils/late_fee_notice.dart";
import "package:onefitness/core/utils/membership_utils.dart";
import "package:onefitness/core/utils/schedule_day_fill.dart";
import "package:onefitness/data/models/availability_block.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/membership_plan.dart";
import "package:onefitness/data/models/trainer.dart";

Booking book({
  String id = "b1",
  String status = "confirmed",
  String? attendance,
  int slot = 15 * 60,
}) =>
    Booking(
      id: id,
      clientId: "c1",
      trainerId: "t1",
      date: "2026-11-18",
      slot: slot,
      sessionType: "one-on-one",
      discipline: "personal-training",
      status: status,
      attendanceStatus: attendance,
    );

Trainer coach({String type = "one-on-one", int slot = 15 * 60}) => Trainer(
      id: "t1",
      name: "Chris McCarthy",
      coachName: "Coach Chris",
      availability: [
        AvailabilityBlock(
          sessionType: type,
          discipline: "personal-training",
          byDay: {3: [slot]},
        ),
      ],
    );

void main() {
  test("a cancel inside 4 hours is the higher fee and still not a used session", () {
    final start = book();
    expect(cancelWindowAt(start, DateTime(2026, 11, 18, 13)), "close");
    expect(cancelWindowAt(start, DateTime(2026, 11, 18, 9)), "late");
    expect(cancelWindowAt(start, DateTime(2026, 11, 17, 19)), "free");
    expect(cancelFeeCentsFor("close"), 2500);
    expect(cancelFeeCentsFor("late"), 1500);
    expect(cancelFeeCentsFor("free"), 0);
    expect(bookingHoldsSeat(book(attendance: "late-cancel")), isFalse);
    expect(bookingHoldsSeat(book(attendance: "no-show")), isTrue);
  });

  test("calendar dots ignore cancels and tell open, booked, and full apart", () {
    final open = scheduleDayFill(
      trainers: [coach()],
      bookings: [book(attendance: "late-cancel"), book(id: "gone", status: "cancelled")],
      blocked: const [],
      date: "2026-11-18",
    );
    expect(open, ScheduleDayFill.open);

    final booked = scheduleDayFill(
      trainers: [coach(type: "semi-private")],
      bookings: [book()],
      blocked: const [],
      date: "2026-11-18",
      semiPrivateCap: 4,
    );
    expect(booked, ScheduleDayFill.booked);

    final full = scheduleDayFill(
      trainers: [coach()],
      bookings: [book()],
      blocked: const [],
      date: "2026-11-18",
    );
    expect(full, ScheduleDayFill.full);

    final quiet = scheduleDayFill(
      trainers: [coach()],
      bookings: const [],
      blocked: const [],
      date: "2026-11-19",
    );
    expect(quiet, isNull);
  });

  test("the booking pitch names the plan and the real fees", () {
    final text = bookingConfirmPitch(
      sessionLabel: "Semi-Private",
      cap: 4,
      coverage: "This comes off your package, 8-pack (5 left to book).",
    );
    expect(text, contains("8-pack"));
    expect(text, contains("5 left to book"));
    expect(text, contains("\$15"));
    expect(text, contains("\$25"));
    expect(text, contains("Cancelling gives it back"));
    expect(text, isNot(contains("uses a session when you book")));

    expect(
      planCoversLargeGroup(MembershipPlan(id: "m", name: "Monthly", kind: PlanKind.membership)),
      isTrue,
    );
    expect(
      planCoversLargeGroup(MembershipPlan(
        id: "p",
        name: "8 pack",
        kind: PlanKind.package,
        allowedTypes: const ["semi-private"],
      )),
      isFalse,
    );
    expect(
      largeGroupBlurb(
        [MembershipPlan(id: "m", name: "Monthly", kind: PlanKind.membership)],
        cap: 15,
      ),
      contains("Covered by Monthly"),
    );
  });

  test("a no-show notice uses the session and a cancel notice gives it back", () {
    expect(
      attendanceMarkedNotice(coachName: "Coach Chris", status: "no-show", cents: 2500),
      contains("used"),
    );
    expect(
      attendanceMarkedNotice(coachName: "Coach Chris", status: "late-cancel", cents: 1500),
      contains("back on your plan"),
    );
    final notice = lateFeeNotice({"charged": true, "feeCents": 2500, "kind": "close"});
    expect(notice, contains("\$25.00"));
    expect(notice, contains("back on your plan"));
  });
}
