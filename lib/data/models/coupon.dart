import "../../core/payments/coupon_duration.dart";

/// Owner-managed coupon-code catalog — reusable named discount codes
/// applicable at checkout (Membership Hub self-checkout, and the
/// coach/owner "Purchase for Client" checkout link). Mirrors the
/// [Product]/[WaiverDoc] catalog convention (single JSONB row per code).
class Coupon {
  const Coupon({
    required this.id,
    required this.code,
    this.type = "percent",
    this.percentOff = 0,
    this.flatOffCents = 0,
    this.archived = false,
    this.duration = couponDurationOnce,
    this.durationInMonths = 1,
  });

  final String id;

  /// Display/entry key — what a buyer types in, and what shows in the
  /// coach's coupon dropdown. Stored upper-cased for case-insensitive entry.
  final String code;

  /// "percent" | "flat".
  final String type;

  /// 1-100, used when [type] is "percent".
  final int percentOff;

  /// Cents, used when [type] is "flat".
  final int flatOffCents;
  final bool archived;

  /// "once" | "forever" | "repeating". Missing on older codes, which stay
  /// one time. A package ignores this and takes the discount once.
  final String duration;

  /// Used when [duration] is "repeating".
  final int durationInMonths;

  String get valueLabel => type == "flat" ? "\$${(flatOffCents / 100).toStringAsFixed(2)} off" : "$percentOff% off";

  String get durationLabel => couponPhrase(
        type: type,
        percentOff: percentOff,
        flatOffCents: flatOffCents,
        duration: duration,
        durationInMonths: durationInMonths,
      );

  /// Membership checkout names the duration. A package does not.
  String checkoutLabel({required bool subscription}) => subscription ? durationLabel : valueLabel;
}
