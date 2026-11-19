import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/package_renewal.dart";

void main() {
  RenewalDecision decide({
    required int remaining,
    int maxSessions = 12,
    int priceCents = 20000,
    bool discountForfeited = false,
    bool alreadyRenewed = false,
  }) =>
      decideRenewal(
        remaining: remaining,
        maxSessions: maxSessions,
        priceCents: priceCents,
        discountForfeited: discountForfeited,
        alreadyRenewed: alreadyRenewed,
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
}
