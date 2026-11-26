import "package:flutter_test/flutter_test.dart";
import "package:supabase_flutter/supabase_flutter.dart" show PostgrestException;

import "package:onefitness/core/utils/booking_limits.dart";
import "package:onefitness/core/utils/booking_utils.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/core/utils/freeze_utils.dart";
import "package:onefitness/core/utils/membership_utils.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/membership_plan.dart";

/// C3, C6, U14 and the held-sessions rule, as the app sees them. The server
/// trigger block_frozen_client_booking uses the same window.
void main() {
  final ten = MembershipPlan(
    id: "ten",
    name: "10 sessions",
    kind: PlanKind.membership,
    maxSessions: 10,
    allowedTypes: const ["semi-private"],
  );

  String inDays(int n) => isoDate(DateTime.parse(isoToday()).add(Duration(days: n)));

  Booking booking(String date, {String id = "b"}) => Booking(
        id: id,
        clientId: "c1",
        trainerId: "t1",
        date: date,
        slot: 12 * 60,
        sessionType: "semi-private",
        discipline: "personal-training",
        status: "confirmed",
        planId: "ten",
      );

  group("which days are frozen", () {
    const running = ClientInfo(
      id: "c1",
      name: "Avery",
      membershipPaused: true,
      membershipPausedAt: "2026-12-01",
      membershipFreezeEndsAt: "2026-12-22",
    );
    test("start day to the day before the end day", () {
      expect(frozenUntilOn(running, "2026-11-30"), isNull);
      expect(frozenUntilOn(running, "2026-12-01"), "2026-12-22");
      expect(frozenUntilOn(running, "2026-12-21"), "2026-12-22");
      expect(frozenUntilOn(running, "2026-12-22"), isNull);
    });

    test("a freeze set for later blocks its own days only (C3)", () {
      const scheduled = ClientInfo(
        id: "c1",
        name: "Avery",
        membershipPausedAt: "2026-12-05",
        membershipFreezeEndsAt: "2026-12-15",
      );
      expect(freezeScheduled(scheduled), isTrue);
      expect(frozenUntilOn(scheduled, "2026-12-04"), isNull);
      expect(frozenUntilOn(scheduled, "2026-12-05"), "2026-12-15");
    });

    test("not frozen at all", () {
      const info = ClientInfo(id: "c1", name: "Avery");
      expect(frozenUntilOn(info, "2026-12-05"), isNull);
      expect(freezeScheduled(info), isFalse);
    });
  });

  group("U14: what a frozen client is told", () {
    test("the end day, and that they can book that day", () {
      expect(
        frozenBookingMessage("2026-12-22"),
        "Your account is frozen until Dec 22. You can book sessions starting that day.",
      );
    });

    test("booking a frozen day in the app", () {
      final info = ClientInfo(
        id: "c1",
        name: "Avery",
        membershipPlanId: "ten",
        membershipPaused: true,
        membershipPausedAt: inDays(-3),
        membershipFreezeEndsAt: inDays(10),
        plans: [ClientPlanEnrollment(planId: "ten", status: "active", startDate: "2026-01-01")],
      );
      final frozen = canBookOffering(info, "semi-private", const [], inDays(3), 12 * 60, [ten]);
      expect(frozen.ok, isFalse);
      expect(frozen.msg, frozenBookingMessage(inDays(10)));
      // The end day itself can be booked while the freeze is still on.
      final after = canBookOffering(info, "semi-private", const [], inDays(10), 12 * 60, [ten]);
      expect(after.reason, isNot("paused"));
    });

    test("the server's sentence is shown as is, to clients and to staff", () {
      const error = PostgrestException(
        message: "Your account is frozen until Dec 22. You can book sessions starting that day.",
        code: "P0001",
        hint: "membership-frozen",
      );
      expect(clientBookingErrorMessage(error), "Your account is frozen until Dec 22. You can book sessions starting that day.");
      const staff = PostgrestException(
        message: "This client's account is frozen until Dec 22. They can be booked starting that day.",
        code: "P0001",
        hint: "membership-frozen",
      );
      expect(staffBookingFailureMessage(staff), "This client's account is frozen until Dec 22. They can be booked starting that day.");
    });
  });

  group("sessions held through a freeze", () {
    ClientInfo withHold({int held = 3, required String from, required String until}) => ClientInfo(
          id: "c1",
          name: "Avery",
          membershipPlanId: "ten",
          plans: [
            ClientPlanEnrollment(
              planId: "ten",
              status: "active",
              startDate: "2026-01-01",
              heldSessions: held,
              frozenFrom: "2026-01-01",
              heldFrom: from,
              heldUntil: until,
            ),
          ],
        );

    test("until the billing day, the held sessions are the allowance", () {
      final info = withHold(from: inDays(-2), until: inDays(5));
      final bookings = [booking(inDays(1), id: "a"), booking(inDays(-10), id: "old")];
      expect(effectiveMaxSessions(info, ten), 3);
      // Only bookings in the window count against it.
      expect(sessionsTowardBookingLimit(info, ten, bookings), 1);
      final left = heldSessionsLeft(info, ten, bookings)!;
      expect(left.left, 2);
      expect(left.until, inDays(5));
      expect(heldSessionsLine(left.left, left.until), "2 sessions left until ${freezeShortDay(inDays(5))}");
      expect(heldSessionsLine(1, "2026-12-21"), "1 session left until Dec 21");
    });

    test("after the billing day the normal allowance is back", () {
      final info = withHold(from: inDays(-9), until: inDays(-2));
      expect(effectiveMaxSessions(info, ten), 10);
      expect(heldSessionsLeft(info, ten, const []), isNull);
    });

    test("the note after an unfreeze", () {
      final plans = withHold(from: inDays(0), until: inDays(5)).plans;
      final line = heldSessionsLineFromPlans(plans);
      expect(line, "3 sessions left until ${freezeShortDay(inDays(5))}");
    });
  });
}
