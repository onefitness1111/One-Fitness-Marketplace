import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/payments/outstanding_balance.dart";
import "package:onefitness/core/utils/booking_limits.dart";
import "package:onefitness/features/trainer/schedule/balance_booking_warning.dart";

void main() {
  group("evaluateBookingBalance single shared rule", () {
    test("non-negative balance is always allowed across roles and targets", () {
      for (final cents in [0, 500]) {
        expect(evaluateBookingBalance(balanceCents: cents, isSelf: true).allowed, isTrue);
        expect(evaluateBookingBalance(balanceCents: cents, isSelf: true, isWaitlist: true).allowed, isTrue);
        expect(evaluateBookingBalance(balanceCents: cents, isSelf: false, isCoach: true, graceUsed: true).allowed, isTrue);
        expect(evaluateBookingBalance(balanceCents: cents, isSelf: false, isOwner: true, graceUsed: true).allowed, isTrue);
      }
    });

    test("client is blocked for both booking and waitlist when owing money", () {
      final book = evaluateBookingBalance(balanceCents: -2500, isSelf: true);
      expect(book.allowed, isFalse);
      expect(book.code, "BALANCE_DUE");
      expect(book.message, "You have an outstanding balance of \$25.00. Please pay your balance to book sessions.");
      expect(bookingBlocked(-2500), isTrue);

      final wait = evaluateBookingBalance(balanceCents: -2500, isSelf: true, isWaitlist: true);
      expect(wait.allowed, isFalse);
      expect(wait.code, "BALANCE_DUE");
      expect(wait.message, book.message);
    });

    test("coach gets one grace booking and is blocked after it is used", () {
      final first = evaluateBookingBalance(balanceCents: -2500, graceUsed: false, isSelf: false, isCoach: true);
      expect(first.allowed, isTrue);
      expect(first.code, "BALANCE_COACH_GRACE");
      expect(first.canOverride, isTrue);

      final second = evaluateBookingBalance(balanceCents: -2500, graceUsed: true, isSelf: false, isCoach: true);
      expect(second.allowed, isFalse);
      expect(second.code, "BALANCE_GRACE_USED");
      expect(second.message, "This client has an outstanding balance of \$25.00.");
    });

    test("coach waitlist add is allowed before grace and blocked after it is used", () {
      final before = evaluateBookingBalance(
        balanceCents: -2500,
        graceUsed: false,
        isSelf: false,
        isCoach: true,
        isWaitlist: true,
      );
      expect(before.allowed, isTrue);
      expect(before.code, "OK");
      expect(before.canOverride, isTrue);

      final after = evaluateBookingBalance(
        balanceCents: -2500,
        graceUsed: true,
        isSelf: false,
        isCoach: true,
        isWaitlist: true,
      );
      expect(after.allowed, isFalse);
      expect(after.code, "BALANCE_GRACE_USED");
      expect(after.message, "This client has an outstanding balance of \$25.00.");
      expect(after.canOverride, isFalse);

      final self = evaluateBookingBalance(
        balanceCents: -2500,
        graceUsed: false,
        isSelf: true,
        isCoach: true,
        isWaitlist: true,
      );
      expect(self.allowed, isFalse);
      expect(self.code, "BALANCE_DUE");
    });

    test("owner can always override balance block even after coach grace is used", () {
      final owner = evaluateBookingBalance(balanceCents: -2500, graceUsed: true, isSelf: false, isOwner: true);
      expect(owner.allowed, isTrue);
      expect(owner.code, "BALANCE_OWNER_OVERRIDE");
      expect(owner.canOverride, isTrue);

      final ownerWaitlist = evaluateBookingBalance(
        balanceCents: -2500,
        graceUsed: true,
        isSelf: false,
        isOwner: true,
        isWaitlist: true,
      );
      expect(ownerWaitlist.allowed, isTrue);
      expect(ownerWaitlist.code, "OK");
      expect(ownerWaitlist.canOverride, isTrue);

      // Owner booking themselves still gets blocked like any self-booking.
      final selfOwner = evaluateBookingBalance(balanceCents: -2500, graceUsed: false, isSelf: true, isOwner: true);
      expect(selfOwner.allowed, isFalse);
      expect(selfOwner.code, "BALANCE_DUE");
    });
  });

  test("unpaidBalanceErrorMessage extracts client and staff errors uniformly", () {
    const clientErr = "PostgrestException(message: BALANCE_DUE: You have an outstanding balance of \$25.00. Please pay your balance to book sessions., code: P0001)";
    expect(unpaidBalanceErrorMessage(clientErr), "You have an outstanding balance of \$25.00. Please pay your balance to book sessions.");
    expect(clientBookingErrorMessage(Exception(clientErr)), "You have an outstanding balance of \$25.00. Please pay your balance to book sessions.");

    const coachErr = "PostgrestException(message: BALANCE_GRACE_USED: This client has an outstanding balance of \$25.00., code: P0001)";
    expect(unpaidBalanceErrorMessage(coachErr), "This client has an outstanding balance of \$25.00.");
    expect(staffBalanceWarningFromError(coachErr), "This client has an outstanding balance of \$25.00.");
    expect(isUnpaidBalanceError(Exception(coachErr)), isTrue);
    expect(isUnpaidBalanceError(Exception("network error")), isFalse);
  });

  test("booking screens and staff sheets all route through the shared check", () {
    final bookingScreen = File("lib/features/client/booking/booking_screen.dart").readAsStringSync();
    expect(bookingScreen, contains("stopForOutstandingBalance(context, info.id, isWaitlist: true)"));
    expect(bookingScreen.contains('contains("BALANCE_DUE")'), isFalse);

    final advScreen = File("lib/features/client/booking/advanced_booking_screen.dart").readAsStringSync();
    expect(advScreen.contains('contains("BALANCE_DUE")'), isFalse);
    expect(advScreen, contains("unpaidBalanceErrorMessage(e)"));

    final staffWarn = File("lib/features/trainer/schedule/balance_booking_warning.dart").readAsStringSync();
    expect(staffWarn, contains("SupabaseService.checkBookingBalance"));
  });
}
