import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/booking_utils.dart";
import "package:onefitness/core/utils/unavailability.dart";
import "package:onefitness/core/utils/unavailability_apply.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/trainer.dart";

Trainer coach(List<TrainerUnavailability> blocks) => Trainer(
      id: "coach-1",
      name: "Chris Legal",
      coachName: "Coach Chris",
      unavailability: blocks,
    );

TrainerUnavailability block({
  String id = "u1",
  String start = "2026-11-25",
  String? end,
  bool? allDay,
  int? startMin,
  int? endMin,
  String? reason,
  String? note,
}) =>
    TrainerUnavailability(
      id: id,
      startDate: start,
      endDate: end ?? start,
      allDay: allDay,
      startMin: startMin,
      endMin: endMin,
      reason: reason,
      note: note,
    );

Booking session({
  String id = "b1",
  String clientId = "c1",
  String date = "2026-11-25",
  int slot = 9 * 60,
  int durationMin = 60,
  String sessionType = "semi-private",
  String? attendance,
  String? planId,
  String status = "confirmed",
}) =>
    Booking(
      id: id,
      clientId: clientId,
      trainerId: "coach-1",
      date: date,
      slot: slot,
      sessionType: sessionType,
      discipline: "strength",
      status: status,
      attendanceStatus: attendance,
      planId: planId,
      durationMin: durationMin,
    );

void main() {
  group("overlap", () {
    test("an all-day block covers every slot that day and no other day", () {
      final u = block(allDay: true, reason: "Vacation");
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 8 * 60), isTrue);
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 21 * 60), isTrue);
      expect(unavailabilityOverlapsSlot(u, "2026-11-24", 9 * 60), isFalse);
      expect(unavailabilityOverlapsSlot(u, "2026-11-26", 9 * 60), isFalse);
      expect(fallsInUnavailability(coach([u]), "2026-11-25"), isTrue);
    });

    test("from a time blocks that minute through the end of the day", () {
      final u = block(allDay: false, startMin: 14 * 60, reason: "Appointment");
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 14 * 60), isTrue);
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 18 * 60), isTrue);
      // 1:00–2:00 ends as the block starts, so it is still bookable.
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 13 * 60), isFalse);
      // 1:30–2:30 runs into the block.
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 13 * 60 + 30), isTrue);
      expect(fallsInUnavailability(coach([u]), "2026-11-25"), isFalse);
      expect(fallsInUnavailability(coach([u]), "2026-11-25", slot: 15 * 60), isTrue);
      expect(fallsInUnavailability(coach([u]), "2026-11-25", slot: 9 * 60), isFalse);
    });

    test("a time range applies on each day and ignores the hours outside it", () {
      final u = block(
        start: "2026-11-25",
        end: "2026-11-27",
        allDay: false,
        startMin: 9 * 60,
        endMin: 12 * 60,
        reason: "Training",
      );
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 9 * 60), isTrue);
      expect(unavailabilityOverlapsSlot(u, "2026-11-26", 11 * 60), isTrue);
      expect(unavailabilityOverlapsSlot(u, "2026-11-27", 9 * 60), isTrue);
      expect(unavailabilityOverlapsSlot(u, "2026-11-28", 9 * 60), isFalse);
      // Ends exactly when the block starts, and starts exactly when it ends.
      expect(unavailabilityOverlapsSlot(u, "2026-11-26", 8 * 60), isFalse);
      expect(unavailabilityOverlapsSlot(u, "2026-11-26", 12 * 60), isFalse);
      expect(fallsInUnavailability(coach([u]), "2026-11-26"), isFalse);
    });

    test("a legacy entry with no times is all day and the note is the reason", () {
      final u = TrainerUnavailability.fromJson({
        "id": "old",
        "startDate": "2026-11-25",
        "endDate": "2026-11-25",
        "note": "Sick",
      });
      expect(u.blocksWholeDay, isTrue);
      expect(u.displayReason, "Sick");
      expect(unavailabilityOverlapsSlot(u, "2026-11-25", 7 * 60), isTrue);
      expect(fallsInUnavailability(coach([u]), "2026-11-25"), isTrue);
      expect(clientUnavailabilityText(u), "Unavailable · Sick · Wed, Nov 25");
    });
  });

  group("who is cancelled", () {
    test("a semi-private session counts every client once", () {
      final u = block(allDay: true, reason: "Away");
      final sessions = affectedSessionsFor(u, [
        session(id: "b1", clientId: "c1"),
        session(id: "b2", clientId: "c2"),
        session(id: "b3", clientId: "c3", slot: 15 * 60, sessionType: "one-on-one"),
      ], trainerId: "coach-1");
      expect(sessions, hasLength(2));
      expect(sessions.first.clients, 2);
      expect(sessions.first.line, contains("Semi-Private"));
      expect(sessions.first.line, contains("2 clients"));
      expect(sessions.last.clients, 1);
    });

    test("a used session and an already-returned session stay as they are", () {
      final u = block(allDay: false, startMin: 9 * 60, reason: "Off");
      final hits = bookingsHitByUnavailability(u, [
        session(id: "in", attendance: "checked-in"),
        session(id: "miss", attendance: "no-show", slot: 10 * 60),
        session(id: "early", attendance: "early-cancel", slot: 11 * 60),
        session(id: "gone", status: "cancelled", slot: 12 * 60),
        session(id: "open", slot: 8 * 60),
        session(id: "keep", slot: 16 * 60),
      ], trainerId: "coach-1");
      expect(hits.map((b) => b.id), ["keep"]);
    });
  });

  group("server rules", () {
    late UnavailabilityApply apply;
    late List<Booking> bookings;

    setUp(() {
      apply = UnavailabilityApply();
      apply.creditBooking["credit-1"] = "single-booking";
      bookings = [
        session(id: "single-booking", clientId: "c1", planId: "single:credit-1", sessionType: "one-on-one"),
        session(id: "pack-booking", clientId: "c2", slot: 10 * 60, planId: "pack-8"),
        session(id: "mate", clientId: "c3", planId: "pack-8"),
        session(id: "used", clientId: "c4", slot: 11 * 60, attendance: "checked-in", planId: "pack-8"),
      ];
    });

    test("a coach can do this for themselves and the owner can do it for any coach", () {
      expect(
        mayEditUnavailability(role: "coach", callerId: "coach-1", trainerId: "coach-1"),
        isTrue,
      );
      expect(
        mayEditUnavailability(role: "owner", callerId: "owner-1", trainerId: "coach-1"),
        isTrue,
      );
      final asCoach = apply.apply(
        role: "coach",
        callerId: "coach-1",
        trainerId: "coach-1",
        entry: block(allDay: true, reason: "Away"),
        bookings: bookings,
      );
      expect(asCoach.cancelledIds, containsAll(["single-booking", "pack-booking", "mate"]));
      expect(asCoach.cancelledIds, isNot(contains("used")));
    });

    test("another coach is refused and nothing is changed", () {
      expect(
        () => apply.apply(
          role: "coach",
          callerId: "coach-2",
          trainerId: "coach-1",
          entry: block(allDay: true, reason: "Away"),
          bookings: bookings,
        ),
        throwsA(isA<UnavailabilityDenied>()),
      );
      expect(apply.creditBooking["credit-1"], "single-booking");
      expect(apply.packageRestoreLog, isEmpty);
      expect(
        () => apply.apply(
          role: "client",
          callerId: "c1",
          trainerId: "coach-1",
          entry: block(id: "u2", allDay: true, reason: "Away"),
          bookings: bookings,
        ),
        throwsA(isA<UnavailabilityDenied>()),
      );
    });

    test("the credit is restored once and a retry does not notify or credit again", () {
      final entry = block(allDay: true, reason: "Away");
      final first = apply.apply(
        role: "owner",
        callerId: "owner-1",
        trainerId: "coach-1",
        entry: entry,
        bookings: bookings,
      );
      expect(apply.creditBooking["credit-1"], isNull);
      expect(first.restoredCreditIds, ["credit-1"]);
      expect(first.restoredPackageBookingIds, ["pack-booking", "mate"]);
      expect(apply.packageRestoreLog, ["pack-booking", "mate"]);
      expect(first.notifiedClientIds, containsAll(["c1", "c2", "c3"]));
      expect(first.notifiedClientIds, isNot(contains("c4")));

      apply.creditBooking["credit-1"] = "single-booking";
      final again = apply.apply(
        role: "owner",
        callerId: "owner-1",
        trainerId: "coach-1",
        entry: entry,
        bookings: bookings,
      );
      expect(again.alreadyApplied, isTrue);
      expect(again.notifiedClientIds, isEmpty);
      expect(apply.creditBooking["credit-1"], "single-booking");
      expect(apply.packageRestoreLog, ["pack-booking", "mate"]);
    });

    test("the database function refuses other coaches, restores credit, and is idempotent", () {
      final sql = File("supabase/migrations/20261120213000_coach_unavailability.sql").readAsStringSync();
      expect(sql, contains("apply_coach_unavailability"));
      expect(sql, contains("v_role is distinct from 'owner'"));
      expect(sql, contains("v_role = 'coach' and v_caller = p_trainer_id"));
      expect(sql, contains("You can only set unavailability for yourself."));
      expect(sql, contains("coach_unavailable"));
      expect(sql, contains("alreadyApplied"));
      expect(sql, contains("shouldNotify"));
      expect(sql, contains("single_session_credits"));
      expect(sql, contains("booking_id = null"));
      expect(sql, contains("coach_public_name"));
      expect(sql, contains("'your coach'"));
      expect(sql, contains("channel, read_by_coach"));
      expect(sql, contains("'inapp'"));
      expect(sql.contains("stripe.refunds"), isFalse);
      expect(sql.contains("payment_intent"), isFalse);
      expect(sql, contains("archive_cancelled_booking"));
      expect(sql, contains("Cancelled sessions stay cancelled"));
      expect(sql, contains("remove_coach_unavailability"));
    });
  });
}
