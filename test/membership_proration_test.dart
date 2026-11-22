import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/payments/membership_proration.dart";

void main() {
  final may30 = DateTime.utc(2026, 5, 30, 18);
  final may21 = DateTime.utc(2026, 5, 21, 15);

  test("May 30 on a \$348 plan prorates through June 21", () {
    final quote = membershipFirstCharge(now: may30, priceCents: 34800, anchorDay: 21)!;
    expect(quote.proratedCents, 24697);
    expect(quote.nextChargeDate, "2026-06-21");
    expect(quote.fullMonth, isFalse);
    expect(
      firstChargeSentence(quote: quote),
      "Today \$246.97, prorated through June 21, 2026. Next full charge \$348.00 on June 21, 2026.",
    );
  });

  test("buying on the anchor day is a full month and bills next on the following anchor", () {
    final quote = membershipFirstCharge(now: may21, priceCents: 34800, anchorDay: 21)!;
    expect(quote.proratedCents, 34800);
    expect(quote.fullMonth, isTrue);
    expect(quote.nextChargeDate, "2026-06-21");
    expect(
      firstChargeSentence(quote: quote),
      "Today \$348.00, a full month. Next full charge \$348.00 on June 21, 2026.",
    );
  });

  test("a one-time coupon discounts only the prorated charge", () {
    final quote = membershipFirstCharge(now: may30, priceCents: 34800, anchorDay: 21)!;
    expect(
      firstChargeSentence(quote: quote, couponType: "flat", flatOffCents: 5000, duration: "once"),
      "Today \$196.97, prorated through June 21, 2026 (\$50.00 off, first payment only). Next full charge \$348.00 on June 21, 2026.",
    );
  });

  test("every month also discounts the next full charge", () {
    final quote = membershipFirstCharge(now: may30, priceCents: 34800, anchorDay: 21)!;
    expect(
      firstChargeSentence(quote: quote, couponType: "flat", flatOffCents: 5000, duration: "forever"),
      contains("Next charge \$298.00 on June 21, 2026."),
    );
  });

  test("the day before the anchor uses this month", () {
    final quote = membershipFirstCharge(now: DateTime.utc(2026, 5, 20, 18), priceCents: 34800, anchorDay: 21)!;
    expect(quote.nextChargeDate, "2026-05-21");
    expect(quote.proratedCents, lessThan(34800));
  });

  test("winter midnight stays on the 21st, and the platform day is not hard-coded", () {
    final quote = membershipFirstCharge(now: DateTime.utc(2026, 1, 10, 20), priceCents: 10000, anchorDay: 15)!;
    expect(quote.nextChargeDate, "2026-01-15");
    expect(resolveAnchorDay(clientDay: null, planDay: null, platformDay: 21), 21);
    expect(resolveAnchorDay(clientDay: 7, planDay: 21, platformDay: 15), 7);
  });

  test("the card fee uses the prorated amount", () {
    final quote = membershipFirstCharge(now: may30, priceCents: 34800, anchorDay: 21)!;
    final onProrated = processingFeeCents(enabled: true, structure: "percentage_flat", percent: 2.9, flatCents: 30, baseCents: quote.proratedCents);
    final onFull = processingFeeCents(enabled: true, structure: "percentage_flat", percent: 2.9, flatCents: 30, baseCents: quote.fullCents);
    expect(onProrated, lessThan(onFull));
    expect(onProrated, 746);
  });

  group("owner Charge full price now", () {
    final nov22 = DateTime.utc(2026, 11, 22, 17);

    test("Nov 22 charges the full \$348 today and again on December 21", () {
      final quote = membershipFirstCharge(now: nov22, priceCents: 34800, anchorDay: 21)!;
      expect(quote.proratedCents, 33640);
      expect(quote.nextChargeDate, "2026-12-21");
      expect(firstChargePlanCents(quote, fullFirstCharge: true), 34800);
      expect(firstChargePlanCents(quote), 33640);
      expect(
        firstChargeSentence(quote: quote, fullFirstCharge: true),
        "Today \$348.00, full price. Next full charge \$348.00 on December 21, 2026.",
      );
    });

    test("a coupon comes off the full amount", () {
      final quote = membershipFirstCharge(now: nov22, priceCents: 34800, anchorDay: 21)!;
      expect(
        firstChargeSentence(quote: quote, couponType: "percent", percentOff: 10, fullFirstCharge: true),
        "Today \$313.20, full price (10% off, first payment only). Next full charge \$348.00 on December 21, 2026.",
      );
    });

    test("the card fee uses the full amount", () {
      final quote = membershipFirstCharge(now: nov22, priceCents: 34800, anchorDay: 21)!;
      final fee = processingFeeCents(
        enabled: true,
        structure: "percentage",
        percent: 3,
        flatCents: 0,
        baseCents: firstChargePlanCents(quote, fullFirstCharge: true),
      );
      expect(fee, 1044);
    });

    test("on the anchor day it still reads as a full month", () {
      final quote = membershipFirstCharge(now: may21, priceCents: 34800, anchorDay: 21)!;
      expect(
        firstChargeSentence(quote: quote, fullFirstCharge: true),
        "Today \$348.00, a full month. Next full charge \$348.00 on June 21, 2026.",
      );
    });
  });
}
