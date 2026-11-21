/// What the owner still has to collect.
///
/// Two kinds of money count: a declined charge that was never resolved, and
/// a client whose balance is below zero. Nothing is limited to today.
///
/// Declined card attempts are not stored as their own rows. A failed fee is
/// written onto the client's balance (`client_balance_ledger` status
/// `unpaid`, and `clients.balance_cents` goes negative). There is no
/// `payment_intent.payment_failed` handler in this app. [unresolvedDeclinedCharges]
/// stays 0 until that record exists. Those clients still show on Balances.
int paymentsToCollectCount({
  required Iterable<int> balanceCents,
  int unresolvedDeclinedCharges = 0,
}) {
  final owing = balanceCents.where((cents) => cents < 0).length;
  final declined = unresolvedDeclinedCharges < 0 ? 0 : unresolvedDeclinedCharges;
  return owing + declined;
}

/// "1 payment to collect" or "4 payments to collect".
String paymentsToCollectLabel(int count) {
  if (count == 1) return "1 payment to collect";
  return "$count payments to collect";
}

/// One client who owes the gym. [balanceCents] is negative.
class BalanceDue {
  const BalanceDue({
    required this.clientId,
    required this.name,
    required this.balanceCents,
    required this.reason,
    this.dateIso,
    this.hasCard,
    this.canChargeCard = false,
  });

  final String clientId;

  /// The name coaches and the owner see on the roster.
  final String name;
  final int balanceCents;

  /// What the money was for. Unpaid fees joined, or "Account balance".
  final String reason;

  /// yyyy-MM-dd of the latest unpaid fee. Null when the balance has no fee row.
  final String? dateIso;

  /// Null when the saved-card lookup has not answered yet.
  final bool? hasCard;

  /// True when an unpaid ledger fee can be charged with the existing
  /// charge-client path.
  final bool canChargeCard;

  int get owedCents => balanceCents < 0 ? -balanceCents : 0;

  bool get chargeEnabled => hasCard == true && canChargeCard;
}

class UnpaidFeeLine {
  const UnpaidFeeLine({required this.kind, required this.amountCents, this.dateIso});

  final String kind;
  final int amountCents;
  final String? dateIso;
}

String feeReasonLabel(String kind) {
  switch (kind) {
    case "late":
      return "Late cancellation";
    case "close":
      return "Short-notice cancellation";
    case "noshow":
      return "No-show";
    default:
      return "Fee";
  }
}

/// Unpaid rows from `client_ledger_for`. Paid and waived rows are left out.
List<UnpaidFeeLine> unpaidFeesFromLedgerRows(Iterable<dynamic> rows) {
  final out = <UnpaidFeeLine>[];
  for (final raw in rows) {
    if (raw is! Map) continue;
    if (raw["status"]?.toString() != "unpaid") continue;
    final kind = raw["fee_type"]?.toString() ?? "";
    if (kind != "late" && kind != "close" && kind != "noshow") continue;
    final amount = (raw["amount_cents"] as num?)?.toInt() ?? 0;
    if (amount <= 0) continue;
    final created = raw["created_at"]?.toString() ?? "";
    final date = created.length >= 10 ? created.substring(0, 10) : null;
    out.add(UnpaidFeeLine(kind: kind, amountCents: amount, dateIso: date));
  }
  return out;
}

/// Latest fee date, and a readable reason. Empty fees mean a balance that
/// was set without a fee row.
({String reason, String? dateIso}) balanceReason(List<UnpaidFeeLine> fees) {
  if (fees.isEmpty) return (reason: "Account balance", dateIso: null);
  final labels = <String>[];
  String? latest;
  for (final fee in fees) {
    final label = feeReasonLabel(fee.kind);
    if (!labels.contains(label)) labels.add(label);
    final date = fee.dateIso;
    if (date != null && (latest == null || date.compareTo(latest) > 0)) latest = date;
  }
  return (reason: labels.join(", "), dateIso: latest);
}

String moneyFromCents(int cents) => "\$${(cents.abs() / 100).toStringAsFixed(2)}";
