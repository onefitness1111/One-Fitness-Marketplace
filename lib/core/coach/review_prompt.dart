class CheckedInSession {
  const CheckedInSession({required this.bookingId, required this.trainerId, required this.date});

  final String bookingId;
  final String trainerId;
  final String date;
}

class ReviewDeferral {
  const ReviewDeferral({required this.bookingId, this.deferredOn});

  final String bookingId;

  /// yyyy-MM-dd the client last tapped Not today. Null if they have not.
  final String? deferredOn;
}

/// The newest checked-in session that still needs a rating.
///
/// Not today hides it for the rest of that calendar day. The next day it
/// is asked again, with no cap, until the client submits stars.
/// One session per open: the newest date wins.
String? nextSessionToRate({
  required List<CheckedInSession> checkedIn,
  required Set<String> reviewedBookingIds,
  required List<ReviewDeferral> deferrals,
  required String today,
}) {
  final deferred = {for (final row in deferrals) row.bookingId: row.deferredOn};
  final open = checkedIn.where((session) {
    if (reviewedBookingIds.contains(session.bookingId)) return false;
    final held = deferred[session.bookingId];
    if (held != null && held.compareTo(today) >= 0) return false;
    return true;
  }).toList()
    ..sort((a, b) => b.date.compareTo(a.date));
  if (open.isEmpty) return null;
  return open.first.bookingId;
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
