import "../../data/models/blocked_time.dart";
import "../../data/models/booking.dart";
import "../../data/models/trainer.dart";
import "../utils/booking_utils.dart";
import "../utils/date_utils.dart";

class NextOpenSlot {
  const NextOpenSlot({required this.date, required this.slot});

  final String date;
  final int slot;
}

/// The soonest seat this coach still has, using the same offering and
/// capacity rules as the booking day.
NextOpenSlot? nextOpenSlot({
  required Trainer trainer,
  required List<Booking> bookings,
  required List<BlockedTime> blocked,
  required String today,
  int horizonDays = 14,
  int semiPrivateCap = 4,
}) {
  final start = DateTime.tryParse(today);
  if (start == null) return null;
  for (var i = 0; i < horizonDays; i++) {
    final date = isoDate(start.add(Duration(days: i)));
    final slots = trainerOfferingsOn(trainer, date).map((o) => o.slot).toSet().toList()..sort();
    for (final slot in slots) {
      final offerings = trainerOfferingsOn(trainer, date).where((o) => o.slot == slot);
      if (offerings.isEmpty) continue;
      final len = offerings.first.durationMin;
      if (fallsInUnavailability(trainer, date, slot: slot, sessionLen: len)) continue;
      if (fallsInBlockedTime(blocked, trainer.id, date, slot, sessionLen: len)) continue;
      final cap = capFor(offerings.first.sessionType, semiPrivateCap: semiPrivateCap);
      final taken = bookedCount(bookings, trainer.id, date, slot);
      if (taken < cap) return NextOpenSlot(date: date, slot: slot);
    }
  }
  return null;
}
