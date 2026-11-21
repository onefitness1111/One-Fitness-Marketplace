import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:supabase_flutter/supabase_flutter.dart" show PostgrestException;

import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/utils/booking_limits.dart";
import "package:onefitness/core/utils/scheduling_utils.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/features/trainer/schedule/override_prompt.dart";

/// The live trigger's overlap rule, and the sentences staff and clients see
/// when it refuses a booking. A 12:00 request against a 12:45 booking is the
/// case the old exact-minute check missed.
void main() {
  Booking booking({
    String id = "b1",
    String clientId = "c1",
    String trainerId = "t1",
    String date = "2026-11-21",
    int slot = 12 * 60,
    String sessionType = "semi-private",
    String discipline = "personal-training",
    String status = "confirmed",
    String? attendanceStatus,
  }) => Booking(
    id: id,
    clientId: clientId,
    trainerId: trainerId,
    date: date,
    slot: slot,
    sessionType: sessionType,
    discipline: discipline,
    status: status,
    attendanceStatus: attendanceStatus,
  );

  const overlap = PostgrestException(
    message: "This coach already has a session that overlaps this time slot.",
    code: "P0001",
  );
  const capacity = PostgrestException(
    message: "This session is already at capacity (4/4).",
    code: "P0001",
  );

  group("findTrainerConflict matches the database hour", () {
    test("12:00 overlaps an existing 12:45 with the same coach", () {
      final hit = findTrainerConflict(
        [booking(slot: 12 * 60 + 45, clientId: "jordan")],
        "t1",
        "2026-11-21",
        12 * 60,
        "semi-private",
        "personal-training",
      );
      expect(hit?.clientId, "jordan");
      expect(hit?.slot, 12 * 60 + 45);
    });

    test("an hour apart is not an overlap", () {
      final hit = findTrainerConflict(
        [booking(slot: 13 * 60)],
        "t1",
        "2026-11-21",
        12 * 60,
        "semi-private",
        "personal-training",
      );
      expect(hit, isNull);
    });

    test("59 minutes still overlaps, in either direction", () {
      expect(
        findTrainerConflict(
          [booking(slot: 12 * 60 + 59)],
          "t1",
          "2026-11-21",
          12 * 60,
          "semi-private",
          "personal-training",
        ),
        isNotNull,
      );
      expect(
        findTrainerConflict(
          [booking(slot: 11 * 60 + 1)],
          "t1",
          "2026-11-21",
          12 * 60,
          "semi-private",
          "personal-training",
        ),
        isNotNull,
      );
    });

    test("the same shared session is not a conflict", () {
      // Identical start, type, and discipline: joining the class. Capacity
      // decides that, not the overlap rule.
      final hit = findTrainerConflict(
        [
          booking(id: "a", clientId: "c1"),
          booking(id: "b", clientId: "c2"),
          booking(id: "c", clientId: "c3"),
        ],
        "t1",
        "2026-11-21",
        12 * 60,
        "semi-private",
        "personal-training",
      );
      expect(hit, isNull);
    });

    test("same start but a different discipline is a conflict", () {
      final hit = findTrainerConflict(
        [booking(discipline: "pilates")],
        "t1",
        "2026-11-21",
        12 * 60,
        "semi-private",
        "personal-training",
      );
      expect(hit, isNotNull);
    });

    test("a longer session does not widen the hour", () {
      // The trigger compares start times, not the end staff typed.
      final hit = findTrainerConflict(
        [booking(slot: 13 * 60)],
        "t1",
        "2026-11-21",
        12 * 60,
        "semi-private",
        "personal-training",
      );
      expect(hit, isNull);
    });

    test("a cancelled or early-cancel booking holds no seat", () {
      expect(
        findTrainerConflict(
          [booking(slot: 12 * 60 + 45, status: "cancelled")],
          "t1",
          "2026-11-21",
          12 * 60,
          "semi-private",
          "personal-training",
        ),
        isNull,
      );
      expect(
        findTrainerConflict(
          [booking(slot: 12 * 60 + 45, attendanceStatus: "early-cancel")],
          "t1",
          "2026-11-21",
          12 * 60,
          "semi-private",
          "personal-training",
        ),
        isNull,
      );
    });

    test("another coach or another day does not conflict", () {
      expect(
        findTrainerConflict(
          [booking(slot: 12 * 60 + 45, trainerId: "t2")],
          "t1",
          "2026-11-21",
          12 * 60,
          "semi-private",
          "personal-training",
        ),
        isNull,
      );
      expect(
        findTrainerConflict(
          [booking(slot: 12 * 60 + 45, date: "2026-11-22")],
          "t1",
          "2026-11-21",
          12 * 60,
          "semi-private",
          "personal-training",
        ),
        isNull,
      );
    });

    test("the closest overlapping session is the one named", () {
      final hit = findTrainerConflict(
        [
          booking(id: "early", clientId: "early", slot: 11 * 60 + 15),
          booking(id: "late", clientId: "late", slot: 12 * 60 + 50),
        ],
        "t1",
        "2026-11-21",
        12 * 60,
        "semi-private",
        "personal-training",
      );
      // 11:15 is 45 minutes away; 12:50 is 50.
      expect(hit?.clientId, "early");
    });
  });

  group("what the failure is allowed to say", () {
    test("the owner prompt names the coach, the time, and the client", () {
      expect(
        ownerOverlapOverrideMessage(
          coachName: "Coach Chris",
          conflictSlot: 12 * 60 + 45,
          clientName: "Jordan",
        ),
        "Coach Chris already has a session at 12:45 PM with Jordan. Book anyway?",
      );
    });

    test("a missing coach name does not fall back to a legal name", () {
      expect(
        ownerOverlapOverrideMessage(
          coachName: "",
          conflictSlot: 12 * 60 + 45,
          clientName: "Jordan",
        ),
        startsWith("This coach already has a session at 12:45 PM"),
      );
      expect(
        ownerOverlapOverrideMessage(
          coachName: "your coach",
          conflictSlot: 9 * 60,
          clientName: "Jordan",
        ),
        "This coach already has a session at 9:00 AM with Jordan. Book anyway?",
      );
    });

    test("without a local row the overlap prompt stays general", () {
      expect(
        ownerOverlapOverrideMessage(coachName: "Coach Chris"),
        "Coach Chris already has a session that overlaps this time. Book anyway?",
      );
    });

    test("capacity keeps the count when the server sent one", () {
      expect(capacityPairFromError(capacity), (4, 4));
      expect(
        ownerCapacityOverrideMessage(clientName: "Jordan", count: 4, cap: 4),
        "This session is at capacity (4/4). Add Jordan anyway?",
      );
      expect(
        overrideReasonFor(
          BookingLimitKind.capacity,
          detail: overrideDetail(
            ownerCapacityOverrideMessage(
              clientName: "Jordan",
              count: 4,
              cap: 4,
            ),
          ),
        ),
        "capacity — This session is at capacity (4/4).",
      );
    });

    test("the stored reason describes the overlap the owner confirmed", () {
      final prompt = ownerOverlapOverrideMessage(
        coachName: "Coach Chris",
        conflictSlot: 12 * 60 + 45,
        clientName: "Jordan",
      );
      expect(
        overrideReasonFor(
          BookingLimitKind.overlap,
          detail: overrideDetail(prompt),
        ),
        "conflict — Coach Chris already has a session at 12:45 PM with Jordan.",
      );
    });

    test("a coach hears the real reason, not the connection", () {
      expect(
        staffBookingFailureMessage(overlap),
        "This coach already has a session at that time.",
      );
      expect(staffBookingFailureMessage(capacity), "That session is full.");
      expect(
        staffBookingFailureMessage(overlap).toLowerCase(),
        isNot(contains("connection")),
      );
      expect(
        staffBookingFailureMessage(capacity).toLowerCase(),
        isNot(contains("connection")),
      );
    });

    test("a coach still hears a human sentence from the server", () {
      final restricted = PostgrestException(
        message:
            "This client is restricted from booking until the owner lifts it.",
        code: "P0001",
      );
      expect(
        staffBookingFailureMessage(restricted),
        "This client is restricted from booking until the owner lifts it.",
      );
      expect(
        staffBookingFailureMessage(restricted).toLowerCase(),
        isNot(contains("connection")),
      );
    });

    test("a permission refusal is not called a connection problem", () {
      final denied = PostgrestException(
        message: "new row violates row-level security policy",
        code: "42501",
      );
      final msg = staffBookingFailureMessage(denied);
      expect(msg.toLowerCase(), isNot(contains("connection")));
      expect(msg, "Couldn't book that session. Please try again.");
    });

    test("only a real network failure mentions the connection", () {
      expect(
        staffBookingFailureMessage(
          Exception("SocketException: failed host lookup"),
        ),
        bookingConnectionMessage,
      );
      expect(isBookingNetworkError(overlap), isFalse);
    });

    test("a client hears the coach's situation and never another client", () {
      expect(clientBookingErrorMessage(overlap), clientOverlapRefusal);
      expect(clientBookingErrorMessage(capacity), clientCapacityRefusal);
      expect(clientBookingErrorMessage(overlap), isNot(contains("Jordan")));
      expect(
        clientBookingErrorMessage(overlap).toLowerCase(),
        isNot(contains("connection")),
      );
      expect(
        clientBookingErrorMessage(capacity).toLowerCase(),
        isNot(contains("connection")),
      );
    });

    test("a client's network failure is the only connection message", () {
      expect(
        clientBookingErrorMessage(
          Exception("ClientException: connection closed"),
        ),
        bookingConnectionMessage,
      );
      final other = PostgrestException(
        message: "duplicate key value",
        code: "23505",
      );
      expect(
        clientBookingErrorMessage(other).toLowerCase(),
        isNot(contains("connection")),
      );
      expect(
        clientBookingErrorMessage(other),
        "Couldn't book that session. Please try again.",
      );
    });

    test("a wrapped trigger message is still recognised", () {
      final wrapped = Exception(
        "PostgrestException(message: This coach already has a session that overlaps this time slot., code: P0001)",
      );
      expect(classifyBookingLimitError(wrapped), BookingLimitKind.overlap);
      expect(staffBookingFailureMessage(wrapped), coachOverlapRefusal);
    });

    test("balance and waiver messages for a client stay as they were", () {
      expect(
        clientBookingErrorMessage(
          Exception(
            "BALANCE_DUE: You have an outstanding balance of \$25.00. Please pay your balance to book sessions.",
          ),
        ),
        "You have an outstanding balance of \$25.00. Please pay your balance to book sessions.",
      );
      expect(
        clientBookingErrorMessage(Exception("waiver-required")),
        "Please sign the waiver under Signatures (in the menu) before booking.",
      );
    });
  });

  testWidgets(
    "the override dialog keeps the card palette and the Override button",
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => confirmOwnerOverride(
                context,
                title: "Scheduling conflict",
                message:
                    "Coach Chris already has a session at 12:45 PM with Jordan. Book anyway?",
              ),
              child: const Text("open"),
            ),
          ),
        ),
      );
      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();

      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.backgroundColor, AppColors.card);
      expect(find.text("Scheduling conflict"), findsOneWidget);
      expect(
        find.text(
          "Coach Chris already has a session at 12:45 PM with Jordan. Book anyway?",
        ),
        findsOneWidget,
      );
      expect(find.text("Override"), findsOneWidget);
      expect(find.text("Cancel"), findsOneWidget);
    },
  );
}
