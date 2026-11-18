import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/booking_utils.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/core/utils/rebook.dart";
import "package:onefitness/data/models/availability_block.dart";
import "package:onefitness/data/models/blocked_time.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/membership_plan.dart";
import "package:onefitness/data/models/trainer.dart";

void main() {
  final yesterday = addDaysIso(isoToday(), -1);
  final nextWeek = addDaysIso(yesterday, 7);
  final weekday = weekdayOf(yesterday);
  final now = DateTime.now();

  Booking session({
    String? date,
    int slot = 540,
    String attendance = "checked-in",
    String sessionType = "semi-private",
    bool assessment = false,
    String status = "confirmed",
  }) =>
      Booking(
        id: "b1",
        clientId: "c1",
        trainerId: "t1",
        date: date ?? yesterday,
        slot: slot,
        sessionType: sessionType,
        discipline: "strength",
        status: status,
        attendanceStatus: attendance,
        planId: "pack",
        isPhysicalAssessment: assessment,
      );

  final info = ClientInfo(
    id: "c1",
    name: "Eric",
    membershipPlanId: "pack",
    plans: const [
      ClientPlanEnrollment(planId: "pack", status: "active", startDate: "2026-01-01"),
    ],
  );

  MembershipPlan plan({int maxSessions = 12}) => MembershipPlan(
        id: "pack",
        name: "12 pack",
        kind: PlanKind.package,
        maxSessions: maxSessions,
        allowedTypes: const ["semi-private", "one-on-one"],
      );

  Trainer coach({
    Map<int, List<int>>? byDay,
    List<TrainerUnavailability> away = const [],
    String? coachName = "Coach Chris",
    String legalName = "Christopher Velorio",
  }) =>
      Trainer(
        id: "t1",
        name: legalName,
        coachName: coachName,
        availability: [
          AvailabilityBlock(
            sessionType: "semi-private",
            discipline: "strength",
            byDay: byDay ?? {weekday: const [540]},
          ),
        ],
        unavailability: away,
      );

  RebookAvailability check({
    Booking? ended,
    Trainer? withCoach,
    List<Booking> extra = const [],
    List<BlockedTime> blocked = const [],
    int maxSessions = 12,
    bool paused = false,
    BookingCheck? waiver,
    int cap = 4,
  }) =>
      rebookSameTimeNextWeek(
        session: ended ?? session(),
        now: now,
        coach: withCoach ?? coach(),
        bookings: [ended ?? session(), ...extra],
        blocked: blocked,
        info: paused ? info.copyWith(membershipPaused: true) : info,
        plans: [plan(maxSessions: maxSessions)],
        waiver: waiver,
        semiPrivateCap: cap,
      );

  test("the same coach and time next week is open after the session ends", () {
    final offer = check();
    expect(offer.open, isTrue);
    expect(offer.date, nextWeek);
    expect(offer.slot, 540);
    expect(offer.coachName, "Coach Chris");
    expect(offer.coachName, isNot(contains("Velorio")));
    expect(offer.planId, "pack");
  });

  test("a session that has not ended is not offered", () {
    final offer = check(ended: session(date: addDaysIso(isoToday(), 1), attendance: "checked-in"));
    expect(offer.open, isFalse);
    expect(offer.reason, "not-ended");
  });

  test("a cancel or a no-show is not offered", () {
    expect(check(ended: session(attendance: "late-cancel")).reason, "cancelled");
    expect(check(ended: session(attendance: "no-show")).reason, "no-show");
  });

  test("a full class is not open", () {
    final taken = List.generate(
      4,
      (i) => Booking(
        id: "other-$i",
        clientId: "someone-$i",
        trainerId: "t1",
        date: nextWeek,
        slot: 540,
        sessionType: "semi-private",
        discipline: "strength",
      ),
    );
    final offer = check(extra: taken);
    expect(offer.open, isFalse);
    expect(offer.reason, "full");
  });

  test("a one-on-one seat that is already taken is not open", () {
    final withOneOnOne = Trainer(
      id: "t1",
      name: "Christopher Velorio",
      coachName: "Coach Chris",
      availability: [
        AvailabilityBlock(
          sessionType: "one-on-one",
          discipline: "strength",
          byDay: {weekday: const [540]},
        ),
      ],
    );
    final taken = Booking(
      id: "other",
      clientId: "someone",
      trainerId: "t1",
      date: nextWeek,
      slot: 540,
      sessionType: "one-on-one",
      discipline: "strength",
    );
    final offer = check(
      ended: session(sessionType: "one-on-one"),
      withCoach: withOneOnOne,
      extra: [taken],
    );
    expect(offer.open, isFalse);
    expect(offer.reason, "full");
  });

  test("the coach not offering that weekday means it is not open", () {
    final offer = check(withCoach: coach(byDay: const {}));
    expect(offer.open, isFalse);
    expect(offer.reason, "not-offered");
  });

  test("a day off or a blocked hour is not open", () {
    final away = check(
      withCoach: coach(away: [
        TrainerUnavailability(id: "u", startDate: nextWeek, endDate: nextWeek),
      ]),
    );
    expect(away.reason, "away");

    final blocked = check(blocked: [
      BlockedTime(id: "blk", trainerId: "t1", date: nextWeek, allDay: true),
    ]);
    expect(blocked.reason, "blocked");
  });

  test("already booked at that time, or no sessions left, is not open", () {
    final clash = Booking(
      id: "mine",
      clientId: "c1",
      trainerId: "t1",
      date: nextWeek,
      slot: 540,
      sessionType: "semi-private",
      discipline: "strength",
      planId: "pack",
    );
    expect(check(extra: [clash]).reason, "conflict");

    final spent = check(maxSessions: 1);
    expect(spent.open, isFalse);
    expect(spent.reason, "budget");
  });

  test("a paused membership or an unsigned waiver is not open", () {
    expect(check(paused: true).reason, "paused");
    final waiver = check(
      waiver: const BookingCheck(ok: false, reason: "waiver-required", msg: "Sign the waiver first."),
    );
    expect(waiver.reason, "waiver-required");
  });

  test("the latest ended session is the one that can be rebooked", () {
    final older = session(slot: 540);
    final newer = session(slot: 600);
    final picked = latestEndedSession(
      [older, Booking(id: "b2", clientId: "c1", trainerId: "t1", date: yesterday, slot: 600, sessionType: "semi-private", discipline: "strength", attendanceStatus: "checked-in", planId: "pack")],
      "c1",
      now,
    );
    expect(picked?.id, "b2");
    expect(newer.slot, 600);
  });
}
