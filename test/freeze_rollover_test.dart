import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/membership_rollover.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/membership_plan.dart";

/// L6: no sessions roll over from a month the client was frozen in, or that
/// was covered by sessions held from a freeze. Same rule as
/// monthTouchedByFreeze in supabase/functions/_shared/membershipFreeze.mjs.
void main() {
  final ten = MembershipPlan(
    id: "ten",
    name: "10 sessions",
    kind: PlanKind.membership,
    maxSessions: 10,
    rolloverEnabled: true,
    rolloverMaxVisits: 4,
  );

  test("a frozen month rolls nothing but is stamped", () {
    const e = ClientPlanEnrollment(planId: "ten", status: "active", startDate: "2026-01-01");
    final frozen = rollMembershipMonth(plan: ten, enrollment: e, bookings: const [], newMonth: "2026-12", frozen: true)!;
    expect(frozen.rolloverSessions, 0);
    expect(frozen.rolloverMonth, "2026-12");
    final normal = rollMembershipMonth(plan: ten, enrollment: e, bookings: const [], newMonth: "2026-12")!;
    expect(normal.rolloverSessions, 4);
  });

  test("which months a freeze touches", () {
    const held = ClientPlanEnrollment(
      planId: "ten",
      status: "active",
      startDate: "2026-01-01",
      heldSessions: 3,
      frozenFrom: "2026-11-05",
      heldFrom: "2026-12-10",
      heldUntil: "2026-12-21",
    );
    const info = ClientInfo(id: "c1", name: "Avery");
    expect(monthTouchedByFreeze("2026-10", held, info), isFalse);
    expect(monthTouchedByFreeze("2026-11", held, info), isTrue);
    expect(monthTouchedByFreeze("2026-12", held, info), isTrue);
    expect(monthTouchedByFreeze("2027-01", held, info), isFalse);

    const paused = ClientInfo(
      id: "c1",
      name: "Avery",
      membershipPaused: true,
      membershipPausedAt: "2026-10-28",
      membershipFreezeEndsAt: "2026-11-01",
    );
    expect(monthTouchedByFreeze("2026-10", null, paused), isTrue);
    expect(monthTouchedByFreeze("2026-11", null, paused), isFalse);
  });

  test("held-session fields survive a save", () {
    const e = ClientPlanEnrollment(
      planId: "ten",
      status: "active",
      startDate: "2026-01-01",
      heldSessions: 3,
      frozenFrom: "2026-11-05",
      heldFrom: "2026-12-10",
      heldUntil: "2026-12-21",
    );
    final json = e.copyWith(endsAt: "2027-01-01").toJson();
    expect(json["heldSessions"], 3);
    expect(json["frozenFrom"], "2026-11-05");
    expect(json["heldFrom"], "2026-12-10");
    expect(json["heldUntil"], "2026-12-21");
    expect(e.holdActiveOn("2026-12-09"), isFalse);
    expect(e.holdActiveOn("2026-12-10"), isTrue);
    expect(e.holdActiveOn("2026-12-21"), isFalse);
  });
}
