import "../../data/models/charge.dart";

/// True when every row carries `stripe_payment_intent_id`, including when
/// the value is null. An empty list has nothing to mis-count. The
/// dashboard bootstrap payload omits the key, so those rows are not safe
/// to count as unpaid.
bool chargeRowsKnowPaymentIntent(Iterable<Map<String, dynamic>> rows) =>
    rows.every((row) => row.containsKey("stripe_payment_intent_id"));

/// Charges dated [date] (ISO yyyy-MM-dd) that the owner still has to collect.
List<Charge> chargesToCollectOn(Iterable<Charge> charges, String date) => [
  for (final charge in charges)
    if (charge.date == date && chargeNeedsCollecting(charge)) charge,
];

/// Whether this ledger row is money the gym has not collected yet.
///
/// A row is still due only when it has a positive amount, has not been
/// waived, and was not already paid. Paid means either of:
///
/// * `type == "purchase"`. Purchases are taken at checkout. A card charge
///   stores a Stripe PaymentIntent (single sessions, memberships). A staff
///   comp is the same type with no PaymentIntent. The Financial ledger's
///   action on these rows is Refund.
/// * a Stripe PaymentIntent id on the row. Charge card (`charge-client`)
///   inserts a `late` or `noshow` row only after that PaymentIntent
///   succeeds, and stores the id. A decline does not insert a charges row;
///   it goes on the client's balance instead.
///
/// The other types:
///
/// * `refund` is money Stripe already returned (a negative row). Nothing
///   to collect.
/// * `manual` is Add Charge on the client profile: a ledger entry for the
///   owner or coach to collect. No Stripe payment is taken there, so it
///   stays due until it is waived or a PaymentIntent is stored on it.
/// * `early_termination_fee` is forgiven by Waive on the Financial ledger
///   (`waive-charge` sets `waivedAt`). Unwaived, and with no PaymentIntent,
///   it is still owed.
/// * `late` and `noshow` from marking attendance (`collectSessionFee`)
///   always insert a row and do not store the PaymentIntent, even when the
///   card succeeds. When the card fails, the fee is also recorded on the
///   client's balance and paid from the balance card, which settles that
///   balance ledger rather than this row. A late or no-show row with no
///   PaymentIntent is treated as still due, because that is the only
///   signal this ledger has for an uncollected fee.
///
/// A null, zero, or negative amount has nothing left to collect. A blank
/// PaymentIntent id counts as no payment.
bool chargeNeedsCollecting(Charge charge) {
  if (charge.waivedAt != null && charge.waivedAt!.trim().isNotEmpty) return false;
  final amount = charge.amount;
  if (amount == null || amount <= 0) return false;
  if (charge.type == "purchase" || charge.type == "refund") return false;
  final intent = charge.stripePaymentIntentId?.trim();
  if (intent != null && intent.isNotEmpty) return false;
  return true;
}
