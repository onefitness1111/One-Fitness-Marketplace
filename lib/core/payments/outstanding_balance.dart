/// Unpaid late-cancel and no-show fees.
///
/// A negative balance means the client owes the gym. Booking stays closed
/// until that balance is paid or the owner waives it. Card numbers never
/// appear here.

const balanceDueLead = "You have an outstanding balance of";

enum FeeKind { late, close, noshow }

class LedgerRow {
  const LedgerRow({
    required this.type,
    required this.amountCents,
    required this.status,
    this.sessionId,
    this.createdBy,
    this.stripePaymentIntentId,
    this.stripePaymentMethodId,
  });

  final FeeKind type;
  final int amountCents;
  final String? sessionId;
  final String? createdBy;

  /// unpaid, paid, or waived.
  final String status;
  final String? stripePaymentIntentId;
  final String? stripePaymentMethodId;

  LedgerRow copyWith({
    String? status,
    String? stripePaymentIntentId,
    String? stripePaymentMethodId,
  }) =>
      LedgerRow(
        type: type,
        amountCents: amountCents,
        status: status ?? this.status,
        sessionId: sessionId,
        createdBy: createdBy,
        stripePaymentIntentId: stripePaymentIntentId ?? this.stripePaymentIntentId,
        stripePaymentMethodId: stripePaymentMethodId ?? this.stripePaymentMethodId,
      );
}

class BalanceAccount {
  const BalanceAccount({this.balanceCents = 0, this.ledger = const []});

  /// Negative means they owe. Shown as -$25.00.
  final int balanceCents;
  final List<LedgerRow> ledger;

  bool get owes => balanceCents < 0;
}

/// -$25.00 when they owe, $0.00 when they don't.
String formatSignedMoney(int cents) {
  final body = (cents.abs() / 100).toStringAsFixed(2);
  return cents < 0 ? "-\$$body" : "\$$body";
}

String outstandingBalanceMessage(int balanceCents) {
  final owed = balanceCents < 0 ? -balanceCents : balanceCents;
  return "$balanceDueLead \$${(owed / 100).toStringAsFixed(2)}. Please pay your balance to book sessions.";
}

/// A charge that did not collect the fee. No card, a decline, or a bank
/// check the client never finished (authentication_required) all count.
bool feeGoesOnBalance({
  required bool hasCard,
  required bool chargeSucceeded,
  String? failureCode,
}) {
  if (!hasCard) return true;
  if (!chargeSucceeded) return true;
  switch (failureCode) {
    case "authentication_required":
    case "requires_action":
    case "card_declined":
      return true;
    default:
      return false;
  }
}

/// Records an unpaid fee, or leaves the account alone when the card was charged.
BalanceAccount applyFeeCharge({
  required BalanceAccount account,
  required FeeKind type,
  required int amountCents,
  required bool hasCard,
  required bool chargeSucceeded,
  String? failureCode,
  String? sessionId,
  String? createdBy,
  String? stripePaymentIntentId,
  String? stripePaymentMethodId,
}) {
  if (amountCents <= 0) return account;
  if (!feeGoesOnBalance(hasCard: hasCard, chargeSucceeded: chargeSucceeded, failureCode: failureCode)) {
    return account;
  }
  if (sessionId != null &&
      account.ledger.any((row) => row.sessionId == sessionId && row.status != "waived")) {
    return account;
  }
  return BalanceAccount(
    balanceCents: account.balanceCents - amountCents,
    ledger: [
      ...account.ledger,
      LedgerRow(
        type: type,
        amountCents: amountCents,
        sessionId: sessionId,
        createdBy: createdBy,
        status: "unpaid",
        stripePaymentIntentId: stripePaymentIntentId,
        stripePaymentMethodId: stripePaymentMethodId,
      ),
    ],
  );
}

bool bookingBlocked(int balanceCents) => balanceCents < 0;

/// One card charge for a pay-per session. A negative balance is added on.
/// A credit is not subtracted.
class SingleSessionBill {
  const SingleSessionBill({required this.sessionCents, required this.balanceCents, required this.totalCents});

  final int sessionCents;
  final int balanceCents;
  final int totalCents;

  bool get includesBalance => balanceCents > 0;

  /// Empty when there is nothing owed. Otherwise the line the sheet shows.
  String get breakdown => includesBalance
      ? "Session ${formatSignedMoney(sessionCents)} + balance ${formatSignedMoney(balanceCents)} = total ${formatSignedMoney(totalCents)}"
      : "";
}

SingleSessionBill singleSessionBill({required int sessionCents, required int accountBalanceCents}) {
  final owed = accountBalanceCents < 0 ? -accountBalanceCents : 0;
  return SingleSessionBill(sessionCents: sessionCents, balanceCents: owed, totalCents: sessionCents + owed);
}

/// What staff see before they add someone who owes money.
String staffBalanceWarning(int balanceCents) {
  final owed = balanceCents < 0 ? -balanceCents : balanceCents;
  return "This client has an outstanding balance of \$${(owed / 100).toStringAsFixed(2)}.";
}

/// One unpaid period. [graceUsed] is the coach's one booking for that period.
class BalanceGate {
  const BalanceGate({this.balanceCents = 0, this.graceUsed = false});

  final int balanceCents;
  final bool graceUsed;

  bool get owes => balanceCents < 0;

  BalanceGate copyWith({int? balanceCents, bool? graceUsed}) => BalanceGate(
        balanceCents: balanceCents ?? this.balanceCents,
        graceUsed: graceUsed ?? this.graceUsed,
      );
}

enum StaffAdd { clear, warned, blocked }

/// The owner can add the client any number of times. A coach can add them
/// once. The client is never covered here — they stay fully blocked.
StaffAdd staffAddDecision({required bool isOwner, required BalanceGate gate}) {
  if (!gate.owes) return StaffAdd.clear;
  if (isOwner) return StaffAdd.warned;
  if (!gate.graceUsed) return StaffAdd.warned;
  return StaffAdd.blocked;
}

/// A coach's first add uses the grace booking. The owner's adds do not.
BalanceGate afterStaffAdd({required bool isOwner, required BalanceGate gate}) {
  if (!gate.owes || isOwner) return gate;
  return gate.copyWith(graceUsed: true);
}

/// Paying or waiving the balance back to zero opens a new grace period.
BalanceGate afterBalanceCleared(BalanceGate gate) => const BalanceGate();

/// Paying the full amount owed marks every unpaid row paid and lifts the block.
BalanceAccount payOutstandingBalance(
  BalanceAccount account, {
  required String paymentIntentId,
  String? paymentMethodId,
}) {
  if (!account.owes) return account;
  return BalanceAccount(
    balanceCents: 0,
    ledger: [
      for (final row in account.ledger)
        if (row.status == "unpaid")
          row.copyWith(
            status: "paid",
            stripePaymentIntentId: paymentIntentId,
            stripePaymentMethodId: paymentMethodId,
          )
        else
          row,
    ],
  );
}

/// The owner can clear what a client owes without taking a card.
BalanceAccount waiveOutstandingBalance(BalanceAccount account) {
  if (!account.owes) return account;
  return BalanceAccount(
    balanceCents: 0,
    ledger: [
      for (final row in account.ledger)
        if (row.status == "unpaid") row.copyWith(status: "waived") else row,
    ],
  );
}

/// What a coach is allowed to see: the amount, and nothing else.
class CoachBalanceView {
  const CoachBalanceView({required this.balanceCents});

  final int balanceCents;

  Map<String, dynamic> toJson() => {"balanceCents": balanceCents};
}
