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
