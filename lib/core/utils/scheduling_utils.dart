import "../../data/models/booking.dart";
import "../../data/models/trainer.dart";
import "membership_utils.dart";
import "offered_catalog.dart";

/// Ported from schedulingHelpers.js, trimmed to what the coach-side
/// Scheduling screens need: capacity/conflict checks and weekly-offering
/// lookups, all pure local-array logic (no backend calls in the source
/// either — this is safe to port faithfully).

/// Mirrors `capFor` — default per-session-type capacity. [semiPrivateCap]
/// should be passed the live `platformSettingsProvider` value from any real
/// UI call site — the default here is only the fallback shape (see
/// core/utils/platform_settings.dart).
int capFor(String sessionType, {int semiPrivateCap = 4}) {
  // An owner-set limit wins for any type, including ones they added
  // themselves (Customize Platform → Services).
  final own = LiveCatalog.caps[sessionType];
  if (own != null && own > 0) return own;
  switch (sessionType) {
    case "one-on-one":
      return 1;
    case "semi-private":
      return semiPrivateCap;
    case "large-group":
      return 15;
    case "assessment-call":
    case "assessment-in-person":
      return 1;
    default:
      // A type the owner added with no limit set: treat it as a group class
      // rather than silently capping it at one client.
      return LiveCatalog.sessionTypes?.contains(sessionType) == true ? semiPrivateCap : 1;
  }
}

/// One "session" = every booking sharing a trainer + date + slot.
List<Booking> sessionGroup(List<Booking> bookings, String trainerId, String date, int slot) =>
    bookings.where((b) => b.trainerId == trainerId && b.date == date && b.slot == slot).toList();

class CapacityInfo {
  const CapacityInfo({required this.count, required this.cap});
  final int count;
  final int cap;
  bool get atCap => count >= cap;
}

CapacityInfo capacityInfo(List<Booking> bookings, String trainerId, String date, int slot, String sessionType, {int semiPrivateCap = 4}) {
  final group = sessionGroup(bookings, trainerId, date, slot).where(bookingHoldsSeat).toList();
  return CapacityInfo(count: group.length, cap: capFor(sessionType, semiPrivateCap: semiPrivateCap));
}

/// Minutes. Matches `session_len` in the live `enforce_booking_limits`
/// trigger: two of this coach's sessions overlap when the starts are
/// strictly under an hour apart. An hour apart does not. The length staff
/// typed on one booking does not widen the window — the trigger compares
/// start times only.
const kTrainerOverlapMinutes = 60;

/// A coach can run one shared session at a time.
///
/// A row conflicts when it is the same coach and date, still holds a seat,
/// and starts within [kTrainerOverlapMinutes] of [slot], unless it IS the
/// shared session being joined (identical start, type, and discipline).
/// Joining that session is a capacity question, not a conflict. A 12:00
/// booking against an existing 12:45 one is a conflict; the old check only
/// looked at the exact minute and let that through.
///
/// The closest overlapping booking is the one returned, so the prompt can
/// name 12:45 rather than a session further away.
Booking? findTrainerConflict(List<Booking> bookings, String trainerId, String date, int slot, String sessionType, String discipline) {
  Booking? best;
  var bestDiff = kTrainerOverlapMinutes;
  for (final b in bookings) {
    if (!bookingHoldsSeat(b) || b.trainerId != trainerId || b.date != date) continue;
    final diff = (b.slot - slot).abs();
    if (diff >= kTrainerOverlapMinutes || diff >= bestDiff) continue;
    if (b.slot == slot && b.sessionType == sessionType && b.discipline == discipline) continue;
    best = b;
    bestDiff = diff;
  }
  return best;
}

/// Mirrors `trainerOfferings` — every slot start (minutes) this trainer
/// offers on a given weekday (0=Sunday..6=Saturday), across all their
/// availability blocks.
List<({String sessionType, String discipline, int slot})> trainerOfferings(Trainer trainer, int weekday) {
  final out = <({String sessionType, String discipline, int slot})>[];
  for (final block in trainer.availability) {
    // Deleted in Customize Platform → no longer offered anywhere.
    if (!LiveCatalog.offers(block.sessionType, block.discipline)) continue;
    for (final slot in block.byDay[weekday] ?? const <int>[]) {
      out.add((sessionType: block.sessionType, discipline: block.discipline, slot: slot));
    }
  }
  return out;
}
