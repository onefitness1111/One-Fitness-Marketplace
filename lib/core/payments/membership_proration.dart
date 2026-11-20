import "coupon_duration.dart";

/// First charge of a monthly membership.
///
/// The anchor is 12:00 AM America/Los_Angeles on the billing day. Buying
/// before that day this month pays through this month's anchor. Buying on
/// that day, or after it, pays through next month's anchor. The 21st itself
/// is a full cycle, and the next charge is the following 21st.
///
/// prorated = round(price * (next anchor − start of today) / (next anchor − previous anchor))
class FirstCharge {
  const FirstCharge({
    required this.proratedCents,
    required this.fullCents,
    required this.fullMonth,
    required this.nextChargeDate,
    required this.anchorDay,
  });

  final int proratedCents;
  final int fullCents;
  final bool fullMonth;

  /// yyyy-MM-dd in America/Los_Angeles.
  final String nextChargeDate;
  final int anchorDay;
}

const billingTimeZone = "America/Los_Angeles";

int? clampAnchorDay(int? day) {
  if (day == null || day < 1) return null;
  return day > 28 ? 28 : day;
}

/// Client's own day, then the plan's renewal day, then Customize Platform.
int? resolveAnchorDay({int? clientDay, int? planDay, int? platformDay}) =>
    clampAnchorDay(clientDay ?? planDay ?? platformDay);

FirstCharge? membershipFirstCharge({
  required DateTime now,
  required int priceCents,
  required int? anchorDay,
}) {
  final day = clampAnchorDay(anchorDay);
  final price = priceCents < 0 ? 0 : priceCents;
  if (day == null || price <= 0) return null;

  final today = _pacificDate(now.toUtc());
  final next = today.day < day ? (year: today.year, month: today.month) : _shiftMonth(today.year, today.month, 1);
  final prev = _shiftMonth(next.year, next.month, -1);
  final nextAt = _pacificMidnightUtc(next.year, next.month, day);
  final prevAt = _pacificMidnightUtc(prev.year, prev.month, day);
  final startAt = _pacificMidnightUtc(today.year, today.month, today.day);
  final cycleMs = nextAt.difference(prevAt).inMilliseconds;
  final remainingMs = nextAt.difference(startAt).inMilliseconds;
  final prorated = cycleMs <= 0 || remainingMs == cycleMs ? price : ((price * remainingMs) / cycleMs).round();
  final date = "${next.year.toString().padLeft(4, "0")}-${next.month.toString().padLeft(2, "0")}-${day.toString().padLeft(2, "0")}";
  return FirstCharge(
    proratedCents: prorated,
    fullCents: price,
    fullMonth: prorated == price,
    nextChargeDate: date,
    anchorDay: day,
  );
}

int couponDiscountCents(int priceCents, {required String type, int percentOff = 0, int flatOffCents = 0}) {
  final price = priceCents < 0 ? 0 : priceCents;
  if (price == 0) return 0;
  if (type == "flat") return flatOffCents < 0 ? 0 : (flatOffCents > price ? price : flatOffCents);
  final percent = percentOff.clamp(0, 100);
  return ((price * percent) / 100).round();
}

int ongoingDiscountCents({
  required int fullCents,
  required String duration,
  required String type,
  int percentOff = 0,
  int flatOffCents = 0,
  int durationInMonths = 1,
}) {
  if (duration == "once") return 0;
  if (duration == "repeating" && durationInMonths <= 1) return 0;
  return couponDiscountCents(fullCents, type: type, percentOff: percentOff, flatOffCents: flatOffCents);
}

String money(int cents) {
  final sign = cents < 0 ? "-" : "";
  final abs = cents.abs();
  return "$sign\$${(abs / 100).toStringAsFixed(2)}";
}

String prettyDate(String isoDate) {
  const months = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ];
  final parts = isoDate.split("-");
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  return "${months[month - 1]} $day, ${parts[0]}";
}

String firstChargeSentence({
  required FirstCharge quote,
  String? couponType,
  int percentOff = 0,
  int flatOffCents = 0,
  String duration = "once",
  int durationInMonths = 1,
}) {
  final when = prettyDate(quote.nextChargeDate);
  final hasCoupon = couponType != null;
  final off = hasCoupon
      ? couponDiscountCents(quote.proratedCents, type: couponType, percentOff: percentOff, flatOffCents: flatOffCents)
      : 0;
  final today = quote.proratedCents - off;
  final laterOff = hasCoupon
      ? ongoingDiscountCents(
          fullCents: quote.fullCents,
          duration: duration,
          type: couponType,
          percentOff: percentOff,
          flatOffCents: flatOffCents,
          durationInMonths: durationInMonths,
        )
      : 0;
  final later = quote.fullCents - laterOff;
  final todayWords = quote.fullMonth ? "Today ${money(today)}, a full month" : "Today ${money(today)}, prorated through $when";
  final couponWords = hasCoupon
      ? " (${couponPhrase(type: couponType, percentOff: percentOff, flatOffCents: flatOffCents, duration: duration, durationInMonths: durationInMonths, baseCents: quote.proratedCents)})"
      : "";
  final nextLabel = laterOff > 0 ? "Next charge" : "Next full charge";
  return "$todayWords$couponWords. $nextLabel ${money(later)} on $when.";
}

/// Same fee rule as create-payment-intent: percent and flat add, and a
/// disabled fee is zero. The base is the prorated plan amount on the first
/// bill and the full price after that.
int processingFeeCents({
  required bool enabled,
  required String structure,
  required num percent,
  required int flatCents,
  required int baseCents,
}) {
  if (!enabled || baseCents <= 0) return 0;
  final pct = structure == "flat" ? 0 : (baseCents * (percent / 100)).round();
  final flat = structure == "percentage" ? 0 : flatCents;
  return pct + flat;
}

/// Second Sunday of March through the first Sunday of November, at midnight.
/// The clock change itself is at 2:00 AM, so midnight on either Sunday is
/// unambiguous: March's Sunday is still standard time, November's is still
/// daylight time.
bool _midnightIsDaylight(int year, int month, int day) {
  final start = _nthSunday(year, 3, 2);
  final end = _nthSunday(year, 11, 1);
  final n = month * 100 + day;
  return n > 300 + start && n <= 1100 + end;
}

int _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final offset = (DateTime.sunday - first.weekday) % 7;
  return 1 + offset + (n - 1) * 7;
}

DateTime _pacificMidnightUtc(int year, int month, int day) {
  final hours = _midnightIsDaylight(year, month, day) ? 7 : 8;
  return DateTime.utc(year, month, day, hours);
}

({int year, int month, int day}) _pacificDate(DateTime utc) {
  final u = utc.toUtc();
  final daylight = _instantIsDaylight(u);
  final wall = u.subtract(Duration(hours: daylight ? 7 : 8));
  return (year: wall.year, month: wall.month, day: wall.day);
}

bool _instantIsDaylight(DateTime utc) {
  final start = DateTime.utc(utc.year, 3, _nthSunday(utc.year, 3, 2), 10);
  final end = DateTime.utc(utc.year, 11, _nthSunday(utc.year, 11, 1), 9);
  return !utc.isBefore(start) && utc.isBefore(end);
}

({int year, int month}) _shiftMonth(int year, int month, int delta) {
  final index = year * 12 + (month - 1) + delta;
  return (year: index ~/ 12, month: index % 12 + 1);
}
