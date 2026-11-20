/// Catalog coupon duration. "once" is the default for codes saved before
/// this existed. Packages ignore it and take the discount a single time.
const couponDurationOnce = "once";
const couponDurationForever = "forever";
const couponDurationRepeating = "repeating";

String couponPhrase({
  required String type,
  int percentOff = 0,
  int flatOffCents = 0,
  String duration = couponDurationOnce,
  int durationInMonths = 1,
  int? baseCents,
}) {
  final amount = type == "flat"
      ? "${_money(_cappedFlat(flatOffCents, baseCents))} off"
      : "${percentOff.clamp(0, 100)}% off";
  if (duration == couponDurationForever) return "$amount every month";
  if (duration == couponDurationRepeating) {
    final months = durationInMonths < 1 ? 1 : (durationInMonths > 36 ? 36 : durationInMonths);
    return "$amount for $months month${months == 1 ? "" : "s"}";
  }
  return "$amount, first payment only";
}

int _cappedFlat(int flatOffCents, int? baseCents) {
  final flat = flatOffCents < 0 ? 0 : flatOffCents;
  if (baseCents == null) return flat;
  return flat > baseCents ? baseCents : flat;
}

String _money(int cents) {
  final sign = cents < 0 ? "-" : "";
  return "$sign\$${(cents.abs() / 100).toStringAsFixed(2)}";
}
