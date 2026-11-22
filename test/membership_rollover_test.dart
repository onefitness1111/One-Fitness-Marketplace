import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/membership_rollover.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/membership_plan.dart";

void main() {
  final ten = MembershipPlan(
    id: "ten",
    name: "10 sessions",
    kind: PlanKind.membership,
    maxSessions: 10,
    rolloverEnabled: true,
    rolloverMaxVisits: 4,
  );
  final sixteen = MembershipPlan(
    id: "sixteen",
    name: "16 sessions",
    kind: PlanKind.membership,
    maxSessions: 16,
    rolloverEnabled: true,
    rolloverMaxVisits: 4,
  );

  ClientInfo person({
    String? slot,
    List<ClientPlanEnrollment> plans = const [],
    int? legacy,
    String? legacyMonth,
  }) =>
      ClientInfo(
        id: "c1",
        name: "Avery",
        membershipPlanId: slot,
        plans: plans,
        sessionCountOverride: legacy,
        sessionCountOverrideMonth: legacyMonth,
      );

  ClientPlanEnrollment enrol(
    String planId, {
    int? sessions,
    String? sessionsMonth,
    int? rolloverMax,
    int rollover = 0,
    String? rolloverMonth,
    String start = "2026-06-01",
    String status = "active",
    String? endsAt,
  }) =>
      ClientPlanEnrollment(
        planId: planId,
        status: status,
        startDate: start,
        maxSessionsOverride: sessions,
        maxSessionsOverrideMonth: sessionsMonth,
        rolloverMaxOverride: rolloverMax,
        rolloverSessions: rollover,
        rolloverMonth: rolloverMonth,
        endsAt: endsAt,
      );

  Booking visit(String planId, String date, {String? attendance, String status = "confirmed"}) => Booking(
        id: "$planId-$date-${attendance ?? "open"}",
        clientId: "c1",
        trainerId: "t1",
        date: date,
        slot: 540,
        sessionType: "semi-private",
        discipline: "strength",
        planId: planId,
        status: status,
        attendanceStatus: attendance,
      );

  test("a session override on one membership does not change another", () {
    final info = person(
      slot: "ten",
      plans: [
        enrol("ten", sessions: 19, sessionsMonth: "2026-11"),
        enrol("sixteen"),
      ],
    );
    expect(
      sessionAllowance(
        plan: ten,
        enrollment: activeEnrollment(info, "ten"),
        month: "2026-11",
      ),
      19,
    );
    expect(
      sessionAllowance(
        plan: sixteen,
        enrollment: activeEnrollment(info, "sixteen"),
        month: "2026-11",
      ),
      16,
    );
  });

  test("a legacy client override counts only for the plan in the slot", () {
    final info = person(
      slot: "sixteen",
      legacy: 19,
      legacyMonth: "2026-11",
      plans: [enrol("sixteen"), enrol("ten")],
    );
    expect(
      sessionAllowance(
        plan: sixteen,
        enrollment: activeEnrollment(info, "sixteen"),
        month: "2026-11",
        legacyOverride: 19,
        legacyMonth: "2026-11",
        legacyApplies: info.membershipPlanId == "sixteen",
      ),
      19,
    );
    expect(
      sessionAllowance(
        plan: ten,
        enrollment: activeEnrollment(info, "ten"),
        month: "2026-11",
        legacyOverride: 19,
        legacyMonth: "2026-11",
        legacyApplies: info.membershipPlanId == "ten",
      ),
      10,
    );
  });

  test("a membership override from another month falls back to the plan", () {
    final info = person(slot: "ten", plans: [enrol("ten", sessions: 19, sessionsMonth: "2026-10")]);
    expect(
      sessionAllowance(plan: ten, enrollment: activeEnrollment(info, "ten"), month: "2026-11"),
      10,
    );
  });

  test("rolled sessions add for this month only and do not replace the plan count", () {
    final info = person(
      slot: "ten",
      plans: [enrol("ten", rollover: 3, rolloverMonth: "2026-11")],
    );
    expect(
      sessionAllowance(plan: ten, enrollment: activeEnrollment(info, "ten"), month: "2026-11"),
      13,
    );
    expect(
      sessionAllowance(plan: ten, enrollment: activeEnrollment(info, "ten"), month: "2026-12"),
      10,
    );
  });

  test("a per-client rollover limit of 0 allows none, and a blank one uses the membership", () {
    final custom = person(slot: "ten", plans: [enrol("ten", rolloverMax: 0)]);
    final blank = person(slot: "ten", plans: [enrol("ten")]);
    expect(rolloverCap(ten, activeEnrollment(custom, "ten")), 0);
    expect(rolloverCap(ten, activeEnrollment(blank, "ten")), 4);
    final off = MembershipPlan(
      id: "off",
      name: "No roll",
      kind: PlanKind.membership,
      maxSessions: 8,
    );
    expect(rolloverCap(off, null), 0);
  });

  test("month end rolls unused sessions and stops at the cap", () {
    final enrollment = enrol("ten", rollover: 4, rolloverMonth: "2026-10");
    final bookings = [
      visit("ten", "2026-10-02", attendance: "checked-in"),
      visit("ten", "2026-10-03", attendance: "no-show"),
      visit("ten", "2026-10-04", attendance: "checked-in"),
      visit("ten", "2026-10-05"),
      visit("ten", "2026-10-06", attendance: "early-cancel"),
      visit("sixteen", "2026-10-02", attendance: "checked-in"),
    ];
    // October allowance is 10 + 4 rolled in. Three sessions were used.
    // 11 unused, cap 4, so 4 roll into November. The open booking and the
    // other plan's check-in do not count.
    final rolled = rollMembershipMonth(
      plan: ten,
      enrollment: enrollment,
      bookings: bookings,
      newMonth: "2026-11",
    );
    expect(rolled?.rolloverSessions, 4);
    expect(rolled?.rolloverMonth, "2026-11");
  });

  test("rollover does not compound past the cap and a second run changes nothing", () {
    final first = rollMembershipMonth(
      plan: ten,
      enrollment: enrol("ten"),
      bookings: const [],
      newMonth: "2026-11",
    );
    expect(first?.rolloverSessions, 4);
    final second = rollMembershipMonth(
      plan: ten,
      enrollment: first!,
      bookings: const [],
      newMonth: "2026-11",
    );
    expect(second, isNull);

    final carried = enrol("ten", rollover: 4, rolloverMonth: "2026-11");
    final december = rollMembershipMonth(
      plan: ten,
      enrollment: carried,
      bookings: const [],
      newMonth: "2026-12",
    );
    // November allowance was 14 and none were used, but the cap is still 4.
    expect(december?.rolloverSessions, 4);
    expect(december?.rolloverMonth, "2026-12");
  });

  test("a client who joined this month, or whose plan already ended, gets nothing", () {
    expect(
      rollMembershipMonth(
        plan: ten,
        enrollment: enrol("ten", start: "2026-11-03"),
        bookings: const [],
        newMonth: "2026-11",
      ),
      isNull,
    );
    expect(
      rollMembershipMonth(
        plan: ten,
        enrollment: enrol("ten", endsAt: "2026-10-20"),
        bookings: const [],
        newMonth: "2026-11",
      ),
      isNull,
    );
  });

  test("a custom rollover limit is what the month-end job caps at", () {
    final rolled = rollMembershipMonth(
      plan: ten,
      enrollment: enrol("ten", rolloverMax: 2),
      bookings: const [],
      newMonth: "2026-11",
    );
    expect(rolled?.rolloverSessions, 2);
    final none = rollMembershipMonth(
      plan: ten,
      enrollment: enrol("ten", rolloverMax: 0),
      bookings: const [],
      newMonth: "2026-11",
    );
    expect(none?.rolloverSessions, 0);
    expect(none?.rolloverMonth, "2026-11");
  });

  test("apply to everyone clears this plan only", () {
    final plans = [
      enrol("ten", sessions: 19, sessionsMonth: "2026-11", rolloverMax: 2, rollover: 3, rolloverMonth: "2026-11"),
      enrol("sixteen", sessions: 12, sessionsMonth: "2026-11", rolloverMax: 1),
    ];
    final cleared = clearPlanOverrides(plans, "ten");
    expect(cleared[0].maxSessionsOverride, isNull);
    expect(cleared[0].rolloverMaxOverride, isNull);
    expect(cleared[0].rolloverSessions, 3);
    expect(cleared[1].maxSessionsOverride, 12);
    expect(cleared[1].rolloverMaxOverride, 1);
  });

  test("saving an override writes it on that plan and a new entry starts clean", () {
    final other = enrol("sixteen", sessions: 19, sessionsMonth: "2026-10");
    final saved = withPlanAllowance(
      [other],
      planId: "ten",
      today: "2026-11-22",
      touchSessions: true,
      maxSessionsOverride: 10,
      maxSessionsOverrideMonth: "2026-11",
      touchRollover: true,
      rolloverMaxOverride: 1,
    );
    expect(saved.singleWhere((e) => e.planId == "sixteen").maxSessionsOverride, 19);
    final added = saved.singleWhere((e) => e.planId == "ten");
    expect(added.maxSessionsOverride, 10);
    expect(added.rolloverMaxOverride, 1);
    expect(added.rolloverSessions, 0);
    expect(added.rolloverMonth, isNull);
  });

  test("editing remaining sessions does not count rolled sessions twice", () {
    expect(overrideBaseForRemaining(desiredRemaining: 8, used: 4, rollover: 2), 10);
  });

  test("previous month wraps the year", () {
    expect(previousMonth("2026-01"), "2025-12");
    expect(previousMonth("2026-11"), "2026-10");
  });
}
