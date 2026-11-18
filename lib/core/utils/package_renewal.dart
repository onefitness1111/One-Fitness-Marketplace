import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/membership_plan.dart";
import "membership_utils.dart";

/// A session package offers a renewal when it is running out.
///
/// 8 sessions left, and they have already used at least one: "Renew now at
/// 5% off." Skipping or dismissing that offer forfeits the discount for
/// that package. 2 sessions left (or fewer): a full-price "Renew now."
/// A brand-new package that still has every session is not "running out."
///
/// The server uses these same numbers when it decides the charge. A client
/// cannot ask for the discount after it has been forfeited.

const int kRenewDiscountSessions = 8;
const int kRenewFullPriceSessions = 2;
const int kRenewDiscountPercent = 5;

enum RenewalOffer { none, discount, fullPrice }

class RenewalDecision {
  const RenewalDecision({
    required this.offer,
    required this.priceCents,
    required this.chargeCents,
    required this.discountCents,
    required this.remaining,
  });

  final RenewalOffer offer;
  final int priceCents;

  /// Package price after the discount, before any card fee. The payment
  /// screen adds the fee and is what actually gets confirmed.
  final int chargeCents;
  final int discountCents;
  final int remaining;

  bool get hasOffer => offer != RenewalOffer.none;
}

/// 5% of [priceCents], rounded to the nearest cent. Same rounding the
/// server uses (`Math.round`).
int renewalDiscountCents(int priceCents) {
  if (priceCents <= 0) return 0;
  return (priceCents * kRenewDiscountPercent / 100).round();
}

/// What to offer for one package, and whether the 5% still applies.
///
/// [discountForfeited] is sticky for this package: once they skip or
/// dismiss the 5% offer, later visits do not bring it back. Hitting 2
/// sessions left replaces it with the full-price offer either way.
/// [alreadyRenewed] means this package was already bought again, so we
/// do not offer or charge a second time for the same package.
RenewalDecision decideRenewal({
  required int remaining,
  required int maxSessions,
  required int priceCents,
  required bool discountForfeited,
  bool alreadyRenewed = false,
}) {
  final price = priceCents < 0 ? 0 : priceCents;
  RenewalOffer offer = RenewalOffer.none;
  if (!alreadyRenewed && price > 0 && maxSessions > 0 && remaining < maxSessions) {
    if (remaining <= kRenewFullPriceSessions) {
      offer = RenewalOffer.fullPrice;
    } else if (remaining <= kRenewDiscountSessions && !discountForfeited) {
      offer = RenewalOffer.discount;
    }
  }
  final off = offer == RenewalOffer.discount ? renewalDiscountCents(price) : 0;
  return RenewalDecision(
    offer: offer,
    priceCents: price,
    chargeCents: price - off,
    discountCents: off,
    remaining: remaining < 0 ? 0 : remaining,
  );
}

/// Skip and dismiss do the same thing to the 5% offer: it is gone for
/// this package. The full-price reminder can be closed without changing
/// the price.
bool discountForfeitedBy({
  required RenewalOffer offer,
  required bool skipped,
  required bool dismissed,
}) =>
    offer == RenewalOffer.discount && (skipped || dismissed);

/// One charge per package and offer. A retry of the same offer reuses
/// this key. The full-price offer is a different key, and the server
/// still refuses it when this package was already renewed.
String renewalIdempotencyKey({
  required String clientId,
  required String planId,
  required String enrollmentStart,
  required RenewalOffer offer,
  int attempt = 1,
}) {
  final kind = offer == RenewalOffer.discount ? "discount" : "full";
  final base = "pkg-renew-$clientId-$planId-$enrollmentStart-$kind";
  return attempt <= 1 ? base : "$base-$attempt";
}

/// The active package enrollments that can run out of sessions, oldest
/// first. Programs and memberships are not packages.
List<({MembershipPlan plan, String start})> packageEnrollments(
  ClientInfo info,
  List<MembershipPlan> plans,
) {
  final byId = {for (final p in plans) p.id: p};
  final out = <({MembershipPlan plan, String start})>[];
  final seen = <String>{};
  final enrolled = info.plans.where((e) => e.status == "active").toList()
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  for (final e in enrolled) {
    final plan = byId[e.planId];
    if (plan == null || plan.kind != PlanKind.package || plan.archived) continue;
    if (!seen.add(plan.id)) continue;
    out.add((plan: plan, start: e.startDate));
  }
  return out;
}

/// Sessions still unused on [plan]. Checked-in and no-show count as used.
/// A booking that has not happened yet does not.
int packageSessionsLeft(ClientInfo info, MembershipPlan plan, List<Booking> bookings) =>
    sessionsRemainingBalance(info, plan, bookings);
