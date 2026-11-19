/// Off-session card charges a coach or the owner can start.
///
/// The amounts are the same fee rules as a late cancel and a short-notice
/// cancel: $15 and $25. The server charges those amounts. Card numbers are
/// never part of this.

const lateFeeCents = 1500;
const shortNoticeFeeCents = 2500;

int feeCentsFor(String kind) {
  switch (kind) {
    case "late":
      return lateFeeCents;
    case "close":
    case "noshow":
      return shortNoticeFeeCents;
    default:
      return 0;
  }
}

String feeLabelFor(String kind) {
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

bool mayChargeClient({
  required bool senderIsOwner,
  required String senderId,
  required String? primaryTrainerId,
}) {
  if (senderIsOwner) return true;
  final coach = (primaryTrainerId ?? "").trim();
  return senderId.isNotEmpty && coach == senderId;
}

/// Stripe asks for the card again when the bank wants a new check, or the
/// card itself was declined.
bool chargeNeedsNewCard(String? code) {
  switch (code) {
    case "authentication_required":
    case "card_declined":
    case "expired_card":
    case "incorrect_cvc":
    case "incorrect_number":
    case "processing_error":
      return true;
    default:
      return false;
  }
}

/// A saved card with no street address has to be completed before it is charged.
bool chargeNeedsBillingAddress({required bool hasCard, required bool cardHasAddress}) {
  if (!hasCard) return false;
  return !cardHasAddress;
}
