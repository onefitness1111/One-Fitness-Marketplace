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

const kCoachGraceUsedNote = "You already added them to one session while this is unpaid.";

/// Canonical result of the single shared unpaid-balance check (mirrors SQL
/// `public.unpaid_balance_rule`).
class BookingBalanceCheck {
  const BookingBalanceCheck({
    required this.allowed,
    required this.code,
    this.message,
    this.balanceCents = 0,
    this.graceUsed = false,
    this.canOverride = false,
  });

  final bool allowed;
  final String code;
  final String? message;
  final int balanceCents;
  final bool graceUsed;
  final bool canOverride;

  bool get owes => balanceCents < 0;
}

/// Single shared rule used everywhere in the app (and mirrored 1:1 in SQL
/// `public.unpaid_balance_rule` and Edge `evaluateUnpaidBalance`).
BookingBalanceCheck evaluateBookingBalance({
  required int balanceCents,
  bool graceUsed = false,
  required bool isSelf,
  bool isOwner = false,
  bool isCoach = false,
  bool isWaitlist = false,
}) {
  if (balanceCents >= 0) {
    return BookingBalanceCheck(
      allowed: true,
      code: "OK",
      balanceCents: balanceCents,
      graceUsed: graceUsed,
    );
  }
  if (isWaitlist) {
    if (!isSelf && (isOwner || isCoach)) {
      return BookingBalanceCheck(
        allowed: true,
        code: "OK",
        balanceCents: balanceCents,
        graceUsed: graceUsed,
        canOverride: true,
      );
    }
    return BookingBalanceCheck(
      allowed: false,
      code: "BALANCE_DUE",
      message: outstandingBalanceMessage(balanceCents),
      balanceCents: balanceCents,
      graceUsed: graceUsed,
    );
  }
  if (!isSelf && isOwner) {
    return BookingBalanceCheck(
      allowed: true,
      code: "BALANCE_OWNER_OVERRIDE",
      message: staffBalanceWarning(balanceCents),
      balanceCents: balanceCents,
      graceUsed: graceUsed,
      canOverride: true,
    );
  }
  if (!isSelf && isCoach) {
    if (graceUsed) {
      return BookingBalanceCheck(
        allowed: false,
        code: "BALANCE_GRACE_USED",
        message: staffBalanceWarning(balanceCents),
        balanceCents: balanceCents,
        graceUsed: graceUsed,
      );
    }
    return BookingBalanceCheck(
      allowed: true,
      code: "BALANCE_COACH_GRACE",
      message: staffBalanceWarning(balanceCents),
      balanceCents: balanceCents,
      graceUsed: graceUsed,
      canOverride: true,
    );
  }
  return BookingBalanceCheck(
    allowed: false,
    code: "BALANCE_DUE",
    message: outstandingBalanceMessage(balanceCents),
    balanceCents: balanceCents,
    graceUsed: graceUsed,
  );
}

/// Extracts the clean unpaid-balance sentence from a server exception when
/// present, or null when [error] is unrelated to an unpaid balance.
String? unpaidBalanceErrorMessage(Object error) {
  final text = error.toString();
  if (text.contains("BALANCE_DUE")) {
    final start = text.indexOf(balanceDueLead);
    if (start >= 0) {
      final end = text.indexOf("book sessions.", start);
      if (end >= start) return text.substring(start, end + "book sessions.".length);
    }
    return "You have an outstanding balance. Please pay your balance to book sessions.";
  }
  if (text.contains("BALANCE_GRACE_USED") || text.contains("This client has an outstanding balance")) {
    final start = text.indexOf("This client has an outstanding balance");
    if (start >= 0) {
      final endMatch = RegExp(r'\.(?=\s|$|,|\))').firstMatch(text.substring(start));
      if (endMatch != null) return text.substring(start, start + endMatch.start + 1);
      return text.substring(start);
    }
    return "This client has an outstanding balance.";
  }
  return null;
}

bool bookingBlocked(int balanceCents) =>
    !evaluateBookingBalance(balanceCents: balanceCents, isSelf: true).allowed;

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

/// What the payer sees when the seat filled after the card was charged.
/// [clientName] is set only for the coach or owner who tapped Charge.
/// The text never includes a phone number or an address.
String filledSessionRefundNotice({
  required int chargedCents,
  int balanceCents = 0,
  String? clientName,
}) {
  final charge = formatSignedMoney(chargedCents);
  final name = (clientName ?? "").trim();
  final lead = name.isEmpty
      ? "This session filled before your booking went through. Your $charge charge has been refunded."
      : "$name's session filled before the booking went through. The $charge charge on their card has been refunded.";
  if (balanceCents <= 0) return lead;
  final whose = name.isEmpty ? "Your" : "Their";
  return "$lead $whose outstanding balance of ${formatSignedMoney(balanceCents)} is unchanged.";
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

/// Whether "Book session anyway" is offered, and the note when it is not.
class StaffBalanceChoices {
  const StaffBalanceChoices({required this.bookAnywayEnabled, this.note});

  final bool bookAnywayEnabled;
  final String? note;
}

/// The owner can always book past a balance. A coach can once. After that
/// one grace booking, the coach's button stays off until the balance is paid.
StaffBalanceChoices staffBalanceChoices({required bool isOwner, required BalanceGate gate}) {
  final check = evaluateBookingBalance(
    balanceCents: gate.balanceCents,
    graceUsed: gate.graceUsed,
    isSelf: false,
    isOwner: isOwner,
    isCoach: !isOwner,
  );
  if (check.allowed) {
    return const StaffBalanceChoices(bookAnywayEnabled: true);
  }
  return const StaffBalanceChoices(
    bookAnywayEnabled: false,
    note: kCoachGraceUsedNote,
  );
}

/// The owner can add the client any number of times. A coach can add them
/// once. The client is never covered here — they stay fully blocked.
StaffAdd staffAddDecision({required bool isOwner, required BalanceGate gate}) {
  final check = evaluateBookingBalance(
    balanceCents: gate.balanceCents,
    graceUsed: gate.graceUsed,
    isSelf: false,
    isOwner: isOwner,
    isCoach: !isOwner,
  );
  if (!check.owes) return StaffAdd.clear;
  return check.allowed ? StaffAdd.warned : StaffAdd.blocked;
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
