import "../../data/models/blocked_time.dart";
import "../../data/models/booking.dart";
import "../../data/models/trainer.dart";
import "booking_utils.dart";
import "membership_utils.dart";

/// What a calendar day should show.
///
/// Open: the gym is working and nobody has taken a seat.
/// Booked: at least one seat is taken and at least one is still free.
/// Full: every seat that day is taken.
enum ScheduleDayFill { open, booked, full }

/// One dot for a day on the coach calendar and on the booking week strip.
///
/// Cancelled bookings do not fill a seat. A day with nothing offered and
/// nobody booked has no dot.
ScheduleDayFill? scheduleDayFill({
  required List<Trainer> trainers,
  required List<Booking> bookings,
  required List<BlockedTime> blocked,
  required String date,
  String? sessionType,
  String? discipline,
  String? locationName,
  String? gymLocationName,
  int semiPrivateCap = 4,
  bool skipStarted = false,
  bool Function(Trainer trainer, Offering offering)? keep,
}) {
  final sunday = isSunday(date);
  final trainerIds = trainers.map((t) => t.id).toSet();
  var hadOffering = false;
  var openSeats = 0;
  var takenSeats = 0;
  final counted = <String>{};

  for (final t in trainers) {
    for (final o in trainerOfferingsOn(t, date)) {
      if (sunday && !o.oneOff) continue;
      if (sessionType != null && o.sessionType != sessionType) continue;
      if (discipline != null && o.discipline != discipline) continue;
      final where = o.locationName ?? gymLocationName;
      if (locationName != null && where != locationName) continue;
      if (keep != null && !keep(t, o)) continue;
      if (fallsInUnavailability(t, date, slot: o.slot, sessionLen: o.durationMin)) continue;
      if (fallsInBlockedTime(blocked, t.id, date, o.slot, sessionLen: o.durationMin)) continue;
      if (skipStarted && sessionHasStarted(date, o.slot)) continue;
      hadOffering = true;
      final cap = capFor(o.sessionType, semiPrivateCap: semiPrivateCap);
      final used = bookings.where((b) {
        return bookingHoldsSeat(b) && b.trainerId == t.id && b.date == date && b.slot == o.slot;
      }).length;
      counted.add("${t.id}|${o.slot}");
      final free = cap - used;
      if (free > 0) openSeats += free;
      if (used > 0) takenSeats += used;
    }
  }

  // A booking whose weekly pattern is gone still means the day is booked.
  for (final b in bookings) {
    if (!bookingHoldsSeat(b) || b.date != date || !trainerIds.contains(b.trainerId)) continue;
    if (sessionType != null && b.sessionType != sessionType) continue;
    if (discipline != null && b.discipline != discipline) continue;
    if (counted.contains("${b.trainerId}|${b.slot}")) continue;
    if (skipStarted && sessionHasStarted(date, b.slot)) continue;
    takenSeats += 1;
  }

  if (!hadOffering && takenSeats == 0) return null;
  if (hadOffering && openSeats == 0) return ScheduleDayFill.full;
  if (takenSeats == 0) return ScheduleDayFill.open;
  if (!hadOffering || openSeats > 0) return ScheduleDayFill.booked;
  return ScheduleDayFill.full;
}
