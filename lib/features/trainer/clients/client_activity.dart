import "../../../data/models/booking.dart";
import "../../../data/models/trainer_note.dart";
import "../../../data/models/workout_log.dart";

enum ClientActivityKind { workout, visit, note }

class ClientActivityItem {
  const ClientActivityItem({
    required this.kind,
    required this.at,
    required this.text,
  });

  final ClientActivityKind kind;
  final DateTime at;
  final String text;
}

/// Newest first, at most [limit]. Uses logs, bookings, and notes the client
/// screen already has. Future bookings are not recent activity.
List<ClientActivityItem> recentClientActivity({
  required List<WorkoutLogEntry> logs,
  required List<Booking> bookings,
  required List<TrainerNote> notes,
  required DateTime now,
  int limit = 5,
}) {
  final items = <ClientActivityItem>[
    for (final log in logs)
      if (_logMoment(log) case final at?)
        ClientActivityItem(
          kind: ClientActivityKind.workout,
          at: at,
          text:
              "Logged ${_short(log.dayTitle.trim().isNotEmpty ? log.dayTitle : log.programName)}",
        ),
    for (final booking in bookings)
      if (_isRecentVisit(booking, now))
        ClientActivityItem(
          kind: ClientActivityKind.visit,
          at: _bookingMoment(booking),
          text: booking.attendanceStatus == "checked-in"
              ? "Checked in"
              : "Visit",
        ),
    for (final note in notes)
      if (_noteMoment(note.createdAt, now) case final at?)
        ClientActivityItem(
          kind: ClientActivityKind.note,
          at: at,
          text:
              "Note · ${_short((note.title ?? "").trim().isNotEmpty ? note.title!.trim() : note.details.trim())}",
        ),
  ]..sort((a, b) => b.at.compareTo(a.at));
  if (items.length <= limit) return items;
  return items.sublist(0, limit);
}

/// "Today", "Yesterday", "3d ago", or a short month-and-day.
String relativeActivityWhen(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final delta = today.difference(day).inDays;
  if (delta <= 0) return "Today";
  if (delta == 1) return "Yesterday";
  if (delta < 7) return "${delta}d ago";
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  return "${months[at.month - 1]} ${at.day}";
}

bool _isRecentVisit(Booking booking, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime.parse(booking.date);
  final booked = DateTime(day.year, day.month, day.day);
  return !booked.isAfter(today);
}

DateTime _bookingMoment(Booking booking) {
  final day = DateTime.parse(booking.date);
  return DateTime(
    day.year,
    day.month,
    day.day,
    booking.slot ~/ 60,
    booking.slot % 60,
  );
}

DateTime? _logMoment(WorkoutLogEntry log) {
  final logged = log.loggedAt;
  if (logged != null) {
    final parsed = DateTime.tryParse(logged);
    if (parsed != null) return parsed.toLocal();
  }
  final day = DateTime.tryParse(log.date);
  if (day == null) return null;
  return DateTime(day.year, day.month, day.day);
}

DateTime? _noteMoment(String raw, DateTime now) {
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed.toLocal();
  final match = RegExp(
    r"^([A-Za-z]{3}) (\d{1,2}), (\d{1,2}):(\d{2}) (AM|PM)$",
  ).firstMatch(raw.trim());
  if (match == null) return null;
  const months = {
    "Jan": 1,
    "Feb": 2,
    "Mar": 3,
    "Apr": 4,
    "May": 5,
    "Jun": 6,
    "Jul": 7,
    "Aug": 8,
    "Sep": 9,
    "Oct": 10,
    "Nov": 11,
    "Dec": 12,
  };
  final month = months[match.group(1)];
  if (month == null) return null;
  var hour = int.parse(match.group(3)!);
  final minute = int.parse(match.group(4)!);
  if (match.group(5) == "PM" && hour != 12) hour += 12;
  if (match.group(5) == "AM" && hour == 12) hour = 0;
  return DateTime(now.year, month, int.parse(match.group(2)!), hour, minute);
}

String _short(String text) {
  final clean = text.trim();
  if (clean.length <= 42) return clean;
  return "${clean.substring(0, 41)}…";
}
