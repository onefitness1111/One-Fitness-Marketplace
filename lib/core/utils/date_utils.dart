/// Date/time formatting ported from src/lib/format.js and
/// src/features/bookings/schedulingHelpers.js — only the pieces the
/// client-facing screens need.
library;

String isoToday() {
  final now = DateTime.now();
  return isoDate(now);
}

String isoDate(DateTime d) =>
    "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

const _weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const _months = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
];

/// Mirrors lib/format.js `niceDate` — "2026-08-26" -> "Wed, Aug 26".
String niceDate(String iso) {
  final d = DateTime.parse(iso);
  return "${_weekdays[d.weekday % 7].substring(0, 3)}, ${_months[d.month - 1]} ${d.day}";
}

/// Mirrors lib/helpers.js `dayLabel` — e.g. "Sunday, Jul 27".
String dayLabel(String iso) {
  final d = DateTime.parse(iso);
  return "${_weekdays[d.weekday % 7]}, ${_months[d.month - 1]} ${d.day}";
}

/// Mirrors schedulingHelpers.js `fmtTime`/`fmtSlot` — minutes-from-midnight
/// to "h:mm AM/PM".
String fmtSlot(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  final ampm = h < 12 ? "AM" : "PM";
  return "$h12:${m.toString().padLeft(2, '0')} $ampm";
}

/// Mirrors schedulingHelpers.js `fmtSlotShort` — a compact form used in
/// availability-block day summaries, e.g. "7a 8:30a 6p".
String fmtSlotShort(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  final mm = m == 0 ? "" : ":${m.toString().padLeft(2, '0')}";
  final ampm = h < 12 ? "a" : "p";
  return "$h12$mm$ampm";
}

/// Compact but unambiguous AM/PM form for tight spaces like a month
/// calendar cell — e.g. "9AM", "2:30PM". Unlike [fmtSlotShort]'s single
/// trailing letter, this always spells out AM/PM in full.
String fmtSlotCompactAmPm(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  final mm = m == 0 ? "" : ":${m.toString().padLeft(2, '0')}";
  final ampm = h < 12 ? "AM" : "PM";
  return "$h12$mm$ampm";
}

/// Mirrors lib/format.js `stamp()` — "Jul 27, 3:45 PM", used as the display
/// timestamp on logged chat messages.
/// A stored timestamp shown to a person. An ISO string becomes
/// "Jul 27, 3:45 PM". A value that is already a plain date is left as it is.
String friendlyStamp(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return "";
  final parsed = DateTime.tryParse(trimmed);
  if (parsed == null) return trimmed;
  return stamp(parsed.toLocal());
}

String stamp([DateTime? at]) {
  final d = at ?? DateTime.now();
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? "AM" : "PM";
  return "${_months[d.month - 1]} ${d.day}, $h:${d.minute.toString().padLeft(2, '0')} $ampm";
}

/// yyyy-MM-dd in America/Los_Angeles, which is the gym's calendar day.
String isoTodayPacific([DateTime? now]) => isoDate(pacificWallNow(now));

/// The gym's wall-clock time (America/Los_Angeles) as a plain date-time,
/// whatever time zone the phone is in. Compare it only with other wall
/// times built the same way (e.g. a booking's date + slot minutes).
DateTime pacificWallNow([DateTime? now]) {
  final utc = (now ?? DateTime.now()).toUtc();
  final start = DateTime.utc(utc.year, 3, _nthSunday(utc.year, 3, 2), 10);
  final end = DateTime.utc(utc.year, 11, _nthSunday(utc.year, 11, 1), 9);
  final daylight = !utc.isBefore(start) && utc.isBefore(end);
  final wall = utc.subtract(Duration(hours: daylight ? 7 : 8));
  return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
}

int _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final offset = (DateTime.sunday - first.weekday) % 7;
  return 1 + offset + (n - 1) * 7;
}

