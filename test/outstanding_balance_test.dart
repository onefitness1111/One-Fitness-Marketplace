import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/payments/outstanding_balance.dart";

void main() {
  const empty = BalanceAccount();

  test("no card records an unpaid balance and blocks booking", () {
    final account = applyFeeCharge(
      account: empty,
      type: FeeKind.noshow,
      amountCents: 2500,
      hasCard: false,
      chargeSucceeded: false,
      sessionId: "session-1",
      createdBy: "coach-1",
    );
    expect(account.balanceCents, -2500);
    expect(formatSignedMoney(account.balanceCents), "-\$25.00");
    expect(account.ledger.single.status, "unpaid");
    expect(account.ledger.single.sessionId, "session-1");
    expect(account.ledger.single.createdBy, "coach-1");
    expect(bookingBlocked(account.balanceCents), isTrue);
    expect(
      outstandingBalanceMessage(account.balanceCents),
      "You have an outstanding balance of \$25.00. Please pay your balance to book sessions.",
    );
  });

  test("a decline or an unfinished bank check records the balance", () {
    for (final code in ["card_declined", "authentication_required", "requires_action"]) {
      final account = applyFeeCharge(
        account: empty,
        type: FeeKind.late,
        amountCents: 1500,
        hasCard: true,
        chargeSucceeded: false,
        failureCode: code,
      );
      expect(account.balanceCents, -1500, reason: code);
      expect(account.ledger.single.status, "unpaid");
      expect(bookingBlocked(account.balanceCents), isTrue);
    }
  });

  test("a successful charge does not create a balance", () {
    final account = applyFeeCharge(
      account: empty,
      type: FeeKind.late,
      amountCents: 1500,
      hasCard: true,
      chargeSucceeded: true,
    );
    expect(account.balanceCents, 0);
    expect(account.ledger, isEmpty);
    expect(bookingBlocked(account.balanceCents), isFalse);
  });

  test("skipping the optional card still leaves the balance", () {
    final skipped = applyFeeCharge(
      account: empty,
      type: FeeKind.close,
      amountCents: 2500,
      hasCard: false,
      chargeSucceeded: false,
    );
    expect(skipped.owes, isTrue);
    expect(feeGoesOnBalance(hasCard: false, chargeSucceeded: false), isTrue);
  });

  test("paying the full balance marks the rows paid and unblocks booking", () {
    final owed = applyFeeCharge(
      account: applyFeeCharge(
        account: empty,
        type: FeeKind.late,
        amountCents: 1500,
        hasCard: false,
        chargeSucceeded: false,
        sessionId: "a",
      ),
      type: FeeKind.noshow,
      amountCents: 2500,
      hasCard: true,
      chargeSucceeded: false,
      failureCode: "card_declined",
      sessionId: "b",
    );
    expect(bookingBlocked(owed.balanceCents), isTrue);
    final paid = payOutstandingBalance(owed, paymentIntentId: "pi_1", paymentMethodId: "pm_1");
    expect(paid.balanceCents, 0);
    expect(paid.ledger.every((row) => row.status == "paid"), isTrue);
    expect(paid.ledger.every((row) => row.stripePaymentIntentId == "pi_1"), isTrue);
    expect(bookingBlocked(paid.balanceCents), isFalse);
  });

  test("buying a single session adds the outstanding balance to one charge", () {
    final bill = singleSessionBill(sessionCents: 4000, accountBalanceCents: -2500);
    expect(bill.sessionCents, 4000);
    expect(bill.balanceCents, 2500);
    expect(bill.totalCents, 6500);
    expect(bill.breakdown, "Session \$40.00 + balance \$25.00 = total \$65.00");
    final clear = singleSessionBill(sessionCents: 4000, accountBalanceCents: 0);
    expect(clear.totalCents, 4000);
    expect(clear.breakdown, isEmpty);
  });

  test("a filled session says the charge was refunded and the balance is unchanged", () {
    expect(
      filledSessionRefundNotice(chargedCents: 6500, balanceCents: 2500),
      "This session filled before your booking went through. Your \$65.00 charge has been refunded. "
      "Your outstanding balance of \$25.00 is unchanged.",
    );
    expect(
      filledSessionRefundNotice(chargedCents: 4000),
      "This session filled before your booking went through. Your \$40.00 charge has been refunded.",
    );
    final staff = filledSessionRefundNotice(chargedCents: 6500, balanceCents: 2500, clientName: "Alex Client");
    expect(staff, startsWith("Alex Client's session filled"));
    expect(staff, contains("Their outstanding balance of \$25.00 is unchanged."));
    expect(staff.contains("phone"), isFalse);
  });

  test("book anyway stays available until a coach has used the one grace booking", () {
    const open = BalanceGate(balanceCents: -2500);
    expect(staffBalanceChoices(isOwner: false, gate: open).bookAnywayEnabled, isTrue);
    expect(staffBalanceChoices(isOwner: false, gate: open).note, isNull);
    const used = BalanceGate(balanceCents: -2500, graceUsed: true);
    final coach = staffBalanceChoices(isOwner: false, gate: used);
    expect(coach.bookAnywayEnabled, isFalse);
    expect(coach.note, contains("one session"));
    expect(staffBalanceChoices(isOwner: true, gate: used).bookAnywayEnabled, isTrue);
  });

  test("a coach is warned, may add one session, and is blocked after that", () {
    var gate = const BalanceGate(balanceCents: -2500);
    expect(staffBalanceWarning(gate.balanceCents), "This client has an outstanding balance of \$25.00.");
    expect(staffAddDecision(isOwner: false, gate: gate), StaffAdd.warned);
    gate = afterStaffAdd(isOwner: false, gate: gate);
    expect(gate.graceUsed, isTrue);
    expect(staffAddDecision(isOwner: false, gate: gate), StaffAdd.blocked);
    expect(bookingBlocked(gate.balanceCents), isTrue);
  });

  test("the owner can keep adding, and paying resets the coach's one booking", () {
    var gate = const BalanceGate(balanceCents: -2500, graceUsed: true);
    expect(staffAddDecision(isOwner: true, gate: gate), StaffAdd.warned);
    final afterOwner = afterStaffAdd(isOwner: true, gate: gate);
    expect(afterOwner.graceUsed, isTrue);
    expect(staffAddDecision(isOwner: false, gate: afterOwner), StaffAdd.blocked);
    final cleared = afterBalanceCleared(afterOwner);
    expect(cleared.balanceCents, 0);
    expect(cleared.graceUsed, isFalse);
    expect(staffAddDecision(isOwner: false, gate: cleared), StaffAdd.clear);
    expect(bookingBlocked(cleared.balanceCents), isFalse);
  });

  test("the owner can waive a balance", () {
    final owed = applyFeeCharge(
      account: empty,
      type: FeeKind.noshow,
      amountCents: 2500,
      hasCard: false,
      chargeSucceeded: false,
    );
    final waived = waiveOutstandingBalance(owed);
    expect(waived.balanceCents, 0);
    expect(waived.ledger.single.status, "waived");
    expect(bookingBlocked(waived.balanceCents), isFalse);
  });

  test("a coach sees the amount and not a phone or address", () {
    final view = CoachBalanceView(balanceCents: -2500);
    expect(view.toJson().keys, ["balanceCents"]);
    expect(view.toJson().containsKey("phone"), isFalse);
    expect(view.toJson().containsKey("address"), isFalse);
  });
}
