import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/package_renewal.dart";

void main() {
  RenewalDecision decide({
    required int remaining,
    int maxSessions = 12,
    int priceCents = 20000,
    bool discountForfeited = false,
    bool alreadyRenewed = false,
    RenewalOfferSettings settings = const RenewalOfferSettings(),
  }) =>
      decideRenewal(
        remaining: remaining,
        maxSessions: maxSessions,
        priceCents: priceCents,
        discountForfeited: discountForfeited,
        alreadyRenewed: alreadyRenewed,
        settings: settings,
      );

  test("a package with more than 8 sessions left has no renewal offer", () {
    final d = decide(remaining: 9);
    expect(d.offer, RenewalOffer.none);
    expect(d.discountCents, 0);
  });

  test("8 sessions left on a larger package is 5% off", () {
    final d = decide(remaining: 8);
    expect(d.offer, RenewalOffer.discount);
    expect(d.discountCents, 1000);
    expect(d.chargeCents, 19000);
  });

  test("a brand-new package that still has every session is not offered", () {
    final d = decide(remaining: 8, maxSessions: 8);
    expect(d.offer, RenewalOffer.none);
  });

  test("using one session of an 8-pack opens the 5% offer", () {
    final d = decide(remaining: 7, maxSessions: 8);
    expect(d.offer, RenewalOffer.discount);
    expect(d.chargeCents, 19000);
  });

  test("skipping or dismissing the 5% offer forfeits it for that package", () {
    expect(
      discountForfeitedBy(offer: RenewalOffer.discount, skipped: true, dismissed: false),
      isTrue,
    );
    expect(
      discountForfeitedBy(offer: RenewalOffer.discount, skipped: false, dismissed: true),
      isTrue,
    );
    expect(
      discountForfeitedBy(offer: RenewalOffer.discount, skipped: false, dismissed: false),
      isFalse,
    );
    expect(
      discountForfeitedBy(offer: RenewalOffer.fullPrice, skipped: true, dismissed: true),
      isFalse,
    );

    final after = decide(remaining: 6, discountForfeited: true);
    expect(after.offer, RenewalOffer.none);
    expect(after.discountCents, 0);
    expect(after.chargeCents, 20000);
  });

  test("2 sessions left is full price, even if the discount was never skipped", () {
    final fresh = decide(remaining: 2);
    expect(fresh.offer, RenewalOffer.fullPrice);
    expect(fresh.discountCents, 0);
    expect(fresh.chargeCents, 20000);

    final forfeited = decide(remaining: 2, discountForfeited: true);
    expect(forfeited.offer, RenewalOffer.fullPrice);
    expect(forfeited.chargeCents, 20000);
  });

  test("1 or 0 sessions left is still the full-price renewal", () {
    expect(decide(remaining: 1).offer, RenewalOffer.fullPrice);
    expect(decide(remaining: 0).offer, RenewalOffer.fullPrice);
  });

  test("a package that was already renewed is not charged again", () {
    expect(decide(remaining: 8, alreadyRenewed: true).offer, RenewalOffer.none);
    expect(decide(remaining: 2, alreadyRenewed: true).offer, RenewalOffer.none);
  });

  test("a free package is never a renewal charge", () {
    expect(decide(remaining: 2, priceCents: 0).offer, RenewalOffer.none);
  });

  test("the same renewal always builds the same idempotency key", () {
    const args = (
      clientId: "client-1",
      planId: "pack-12",
      enrollmentStart: "2026-08-01",
    );
    final first = renewalIdempotencyKey(offer: RenewalOffer.discount, clientId: args.clientId, planId: args.planId, enrollmentStart: args.enrollmentStart);
    final again = renewalIdempotencyKey(offer: RenewalOffer.discount, clientId: args.clientId, planId: args.planId, enrollmentStart: args.enrollmentStart);
    final full = renewalIdempotencyKey(offer: RenewalOffer.fullPrice, clientId: args.clientId, planId: args.planId, enrollmentStart: args.enrollmentStart);
    expect(first, again);
    expect(first, isNot(full));
    expect(first, "pkg-renew-client-1-pack-12-2026-08-01-discount");
  });

  test("5% rounds to the nearest cent", () {
    expect(renewalDiscountCents(19999), 1000);
    expect(renewalDiscountCents(100), 5);
  });

  test("a missing offer is today's 5% at 8 sessions left", () {
    expect(RenewalOfferSettings.fromJson(null).enabled, isTrue);
    expect(RenewalOfferSettings.fromJson(null).percent, 5);
    expect(RenewalOfferSettings.fromJson(null).sessionsLeft, 8);
    expect(RenewalOfferSettings.fromJson({}).percent, 5);
    expect(RenewalOfferSettings.fromJson({}).sessionsLeft, 8);

    final d = decide(remaining: 8, settings: RenewalOfferSettings.fromJson(null));
    expect(d.offer, RenewalOffer.discount);
    expect(d.percent, 5);
    expect(d.discountCents, 1000);
    expect(d.chargeCents, 19000);
  });

  test("a saved percent and threshold replace the old 5% and 8", () {
    const settings = RenewalOfferSettings(enabled: true, percent: 12, sessionsLeft: 4);
    final early = decide(remaining: 5, settings: settings);
    expect(early.offer, RenewalOffer.none);
    expect(early.discountCents, 0);
    expect(early.chargeCents, 20000);

    final offered = decide(remaining: 4, settings: settings);
    expect(offered.offer, RenewalOffer.discount);
    expect(offered.percent, 12);
    expect(offered.discountCents, 2400);
    expect(offered.chargeCents, 17600);

    final full = decide(remaining: 2, settings: settings);
    expect(full.offer, RenewalOffer.fullPrice);
    expect(full.percent, 0);
    expect(full.chargeCents, 20000);

    expect(renewalDiscountCents(19999, percent: 12), 2400);
    expect(renewalDiscountCents(100, percent: 1), 1);
    expect(renewalDiscountCents(20000, percent: 50), 10000);
  });

  test("turning the offer off removes the discount and keeps the full-price reminder", () {
    const settings = RenewalOfferSettings(enabled: false, percent: 20, sessionsLeft: 8);
    final quiet = decide(remaining: 8, settings: settings);
    expect(quiet.offer, RenewalOffer.none);
    expect(quiet.discountCents, 0);
    expect(quiet.chargeCents, 20000);

    final stillFull = decide(remaining: 2, settings: settings);
    expect(stillFull.offer, RenewalOffer.fullPrice);
    expect(stillFull.chargeCents, 20000);

    final forfeited = decide(remaining: 6, settings: settings, discountForfeited: true);
    expect(forfeited.offer, RenewalOffer.none);
  });

  test("an out-of-range saved offer falls back to today's numbers", () {
    final settings = RenewalOfferSettings.fromJson({
      "enabled": true,
      "percent": 80,
      "sessionsLeft": 1,
    });
    expect(settings.percent, 5);
    expect(settings.sessionsLeft, 8);
    final d = decide(remaining: 8, settings: settings);
    expect(d.offer, RenewalOffer.discount);
    expect(d.percent, 5);
    expect(d.chargeCents, 19000);
  });

  test("the client wording uses the saved percent", () {
    expect(renewalDiscountTitle(12), "Renew now at 12% off");
    expect(renewalDiscountBanner(12), "RENEW NOW AT 12% OFF");
    expect(
      renewalDiscountBody(planName: "12 Pack", remaining: 4, percent: 12),
      "Your 12 Pack has 4 sessions left. Renew now and the price is 12% off. If you skip this, that discount is gone for this package.",
    );
    expect(
      renewalDiscountQuestion(planName: "12 Pack", percent: 12, chargeCents: 17600, priceCents: 20000),
      "Renew 12 Pack at 12% off? The package price is \$176.00 instead of \$200.00.",
    );
    expect(renewalDiscountTitle(12), isNot(contains("5%")));
  });
}
