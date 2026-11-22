import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/membership_plan.dart";
import "membership_utils.dart";

/// A session package offers a renewal when it is running out.
///
/// The discount percent and the sessions-left threshold come from the
/// owner's package renewal offer (Customize Platform → Coupons). When that
/// offer has never been saved, it is on, at 5%, starting at 8 sessions left
/// — the same offer as before it could be edited.
///
/// Skipping or dismissing the discount forfeits it for that package.
/// 2 sessions left (or fewer): a full-price "Renew now," whether or not the
/// discount is on. A brand-new package that still has every session is not
/// "running out."
///
/// The server reads the same saved offer when it decides the charge. A
/// client cannot send a percent, and cannot ask for the discount after it
/// has been forfeited.

const int kRenewDiscountSessions = 8;
const int kRenewFullPriceSessions = 2;
const int kRenewDiscountPercent = 5;

/// Smallest sessions-left value that can still be a discount. 2 and below
/// is always the full-price reminder.
const int kRenewDiscountSessionsMin = 3;
const int kRenewDiscountSessionsMax = 99;
const int kRenewDiscountPercentMin = 1;
const int kRenewDiscountPercentMax = 50;

enum RenewalOffer { none, discount, fullPrice }

/// The owner's package renewal offer. Missing or out-of-range values fall
/// back to [kRenewDiscountPercent] and [kRenewDiscountSessions] with the
/// offer switched on, so an unsaved row behaves exactly as it does today.
class RenewalOfferSettings {
  const RenewalOfferSettings({
    this.enabled = true,
    this.percent = kRenewDiscountPercent,
    this.sessionsLeft = kRenewDiscountSessions,
  });

  final bool enabled;
  final int percent;
  final int sessionsLeft;

  static const RenewalOfferSettings defaults = RenewalOfferSettings();

  factory RenewalOfferSettings.fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    final enabled = raw["enabled"] is bool ? raw["enabled"] as bool : true;
    return RenewalOfferSettings(
      enabled: enabled,
      percent: _percentOrDefault(raw["percent"]),
      sessionsLeft: _sessionsOrDefault(raw["sessionsLeft"]),
    );
  }

  Map<String, dynamic> toJson() => {
        "enabled": enabled,
        "percent": percent,
        "sessionsLeft": sessionsLeft,
      };

  RenewalOfferSettings copyWith({bool? enabled, int? percent, int? sessionsLeft}) => RenewalOfferSettings(
        enabled: enabled ?? this.enabled,
        percent: percent ?? this.percent,
        sessionsLeft: sessionsLeft ?? this.sessionsLeft,
      );
}

int _percentOrDefault(Object? value) {
  final n = _wholeNumber(value);
  if (n == null || n < kRenewDiscountPercentMin || n > kRenewDiscountPercentMax) {
    return kRenewDiscountPercent;
  }
  return n;
}

int _sessionsOrDefault(Object? value) {
  final n = _wholeNumber(value);
  if (n == null || n < kRenewDiscountSessionsMin || n > kRenewDiscountSessionsMax) {
    return kRenewDiscountSessions;
  }
  return n;
}

int? _wholeNumber(Object? value) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  return null;
}

class RenewalDecision {
  const RenewalDecision({
    required this.offer,
    required this.priceCents,
    required this.chargeCents,
    required this.discountCents,
    required this.remaining,
    required this.percent,
  });

  final RenewalOffer offer;
  final int priceCents;

  /// Package price after the discount, before any card fee. The payment
  /// screen adds the fee and is what actually gets confirmed.
  final int chargeCents;
  final int discountCents;
  final int remaining;

  /// The saved percent when this is a discount offer. 0 otherwise.
  final int percent;

  bool get hasOffer => offer != RenewalOffer.none;
}

/// [percent] of [priceCents], rounded to the nearest cent. Same rounding
/// the server uses (`Math.round`). A percent outside 1–50 is treated as
/// the default 5, so a bad value cannot change the price.
int renewalDiscountCents(int priceCents, {int percent = kRenewDiscountPercent}) {
  if (priceCents <= 0) return 0;
  final rate = percent < kRenewDiscountPercentMin || percent > kRenewDiscountPercentMax
      ? kRenewDiscountPercent
      : percent;
  return (priceCents * rate / 100).round();
}

/// What to offer for one package, and whether the saved discount still applies.
///
/// [discountForfeited] is sticky for this package: once they skip or
/// dismiss the discount, later visits do not bring it back. Hitting 2
/// sessions left replaces it with the full-price offer either way.
/// [alreadyRenewed] means this package was already bought again, so we
/// do not offer or charge a second time for the same package.
/// [settings] is the owner's offer. The default is today's 5% at 8 left.
RenewalDecision decideRenewal({
  required int remaining,
  required int maxSessions,
  required int priceCents,
  required bool discountForfeited,
  bool alreadyRenewed = false,
  RenewalOfferSettings settings = const RenewalOfferSettings(),
}) {
  final price = priceCents < 0 ? 0 : priceCents;
  final percent = _percentOrDefault(settings.percent);
  final sessionsLeft = _sessionsOrDefault(settings.sessionsLeft);
  RenewalOffer offer = RenewalOffer.none;
  if (!alreadyRenewed && price > 0 && maxSessions > 0 && remaining < maxSessions) {
    if (remaining <= kRenewFullPriceSessions) {
      offer = RenewalOffer.fullPrice;
    } else if (settings.enabled && remaining <= sessionsLeft && !discountForfeited) {
      offer = RenewalOffer.discount;
    }
  }
  final off = offer == RenewalOffer.discount ? renewalDiscountCents(price, percent: percent) : 0;
  return RenewalDecision(
    offer: offer,
    priceCents: price,
    chargeCents: price - off,
    discountCents: off,
    remaining: remaining < 0 ? 0 : remaining,
    percent: offer == RenewalOffer.discount ? percent : 0,
  );
}

/// Skip and dismiss do the same thing to the discount offer: it is gone
/// for this package. The full-price reminder can be closed without
/// changing the price.
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

String renewalMoney(int cents) => "\$${(cents / 100).toStringAsFixed(2)}";

/// Sentences the client sees. The percent is the one the server used for
/// the charge, not a fixed number.
String renewalDiscountTitle(int percent) => "Renew now at $percent% off";

String renewalDiscountBanner(int percent) => "RENEW NOW AT $percent% OFF";

String renewalDiscountBody({
  required String planName,
  required int remaining,
  required int percent,
}) =>
    "Your $planName has $remaining sessions left. Renew now and the price is $percent% off. If you skip this, that discount is gone for this package.";

String renewalDiscountQuestion({
  required String planName,
  required int percent,
  required int chargeCents,
  required int priceCents,
}) =>
    "Renew $planName at $percent% off? The package price is ${renewalMoney(chargeCents)} instead of ${renewalMoney(priceCents)}.";

String renewalDiscountStillThere(int percent) => "Couldn't save that, so the $percent% is still available.";

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
    if (plan == null || plan.kind != PlanKind.package || plan.status == PlanStatus.archived) continue;
    if (!seen.add(plan.id)) continue;
    out.add((plan: plan, start: e.startDate));
  }
  return out;
}

/// Sessions still unused on [plan]. Checked-in and no-show count as used.
/// A booking that has not happened yet does not.
int packageSessionsLeft(ClientInfo info, MembershipPlan plan, List<Booking> bookings) =>
    sessionsRemainingBalance(info, plan, bookings);
