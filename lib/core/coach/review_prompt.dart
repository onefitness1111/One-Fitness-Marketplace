import "../utils/date_utils.dart";

/// Only sessions that ended within this window are eligible for a rating ask.
const reviewPromptWindow = Duration(hours: 24);

class CheckedInSession {
  const CheckedInSession({
    required this.bookingId,
    required this.trainerId,
    required this.date,
    this.slot = 0,
    this.durationMin = 60,
    this.clientId,
    this.attendanceStatus = "checked-in",
    this.cancelled = false,
  });

  final String bookingId;
  final String trainerId;
  final String date;
  final int slot;
  final int durationMin;
  final String? clientId;
  final String? attendanceStatus;
  final bool cancelled;
}

class ReviewDeferral {
  const ReviewDeferral({required this.bookingId, this.deferredOn});

  final String bookingId;

  /// yyyy-MM-dd the client tapped Not today. Any row is a permanent dismiss.
  final String? deferredOn;
}

DateTime? _sessionEndWallUtc(CheckedInSession session) {
  final parts = session.date.split("-");
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final dur = session.durationMin > 0 ? session.durationMin : 60;
  return DateTime.utc(year, month, day, 0, session.slot + dur);
}

/// The newest own checked-in, uncancelled session that finished in Pacific
/// time within the last 24 hours, if it has neither a review nor a dismiss.
///
/// Any row in [deferrals] permanently dismisses that session. Only the newest
/// recently finished session is ever considered — there is no backlog walking.
String? nextSessionToRate({
  required List<CheckedInSession> checkedIn,
  required Set<String> reviewedBookingIds,
  required List<ReviewDeferral> deferrals,
  String? currentClientId,
  DateTime? now,
}) {
  final wall = pacificWallNow(now);
  final wallUtc = DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
  final windowStart = wallUtc.subtract(reviewPromptWindow);

  final finished = <({CheckedInSession session, DateTime end})>[];
  for (final session in checkedIn) {
    if (session.bookingId.isEmpty || session.trainerId.isEmpty) continue;
    if (currentClientId != null && session.clientId != currentClientId) continue;
    if (session.cancelled || session.attendanceStatus != "checked-in") continue;
    final end = _sessionEndWallUtc(session);
    if (end == null) continue;
    if (end.isAfter(wallUtc)) continue;
    if (end.isBefore(windowStart)) continue;
    finished.add((session: session, end: end));
  }
  if (finished.isEmpty) return null;

  finished.sort((a, b) {
    final byEnd = b.end.compareTo(a.end);
    if (byEnd != 0) return byEnd;
    final bySlot = b.session.slot.compareTo(a.session.slot);
    if (bySlot != 0) return bySlot;
    return b.session.bookingId.compareTo(a.session.bookingId);
  });

  final newest = finished.first.session;
  if (reviewedBookingIds.contains(newest.bookingId)) return null;
  final dismissedIds = {for (final row in deferrals) row.bookingId};
  if (dismissedIds.contains(newest.bookingId)) return null;
  return newest.bookingId;
}

bool reviewTextAllowed(int stars) => stars >= 1 && stars <= 5;

/// Booking ids from `my_rated_booking_ids`.
///
/// The function returns a list of ids. A row-shaped payload is accepted
/// only for its booking id, so a name or review body never becomes state.
Set<String> ratedBookingIds(dynamic rows) {
  if (rows is! List) return const {};
  return {
    for (final row in rows)
      if (row is String && row.isNotEmpty)
        row
      else if (row is Map && row["booking_id"] != null)
        row["booking_id"].toString(),
  };
}
