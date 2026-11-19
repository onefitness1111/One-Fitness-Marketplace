import "date_utils.dart";
import "../../data/models/booking.dart";

/// How many sessions one coach may have running at the same time.
const kMaxConcurrentLiveSessions = 3;

/// Shown when a fourth start is refused. Rejoining one that is already
/// running is not a new start and does not show this.
const kLiveSessionCapMessage =
    "You already have 3 sessions running. End one before starting another.";

/// A booking counts as arrived when the coach marked them checked in, or
/// when the client started the session themselves. Either one opens Start
/// Session for this slot before the clock reaches it.
bool bookingUnlocksSession(Booking booking) =>
    booking.attendanceStatus == "checked-in" || booking.clientStartedEarly;

/// Whether the coach may start (or rejoin) this slot.
///
/// Allowed when the session is already live, when today has reached the
/// scheduled minute, or when anyone in the slot is checked in. A past day
/// stays closed unless that session is still live. A future day stays closed
/// until someone in it is checked in — the scheduled minute has not arrived.
bool sessionMayStart({
  required String viewDate,
  required String today,
  required int nowMin,
  required int slot,
  required bool someoneCheckedIn,
  bool alreadyLive = false,
}) {
  if (alreadyLive) return true;
  if (viewDate.compareTo(today) < 0) return false;
  if (someoneCheckedIn) return true;
  return viewDate == today && nowMin >= slot;
}

/// Why a start button is still disabled. Null once [sessionMayStart] is true
/// or the day is already over (the button is disabled with no extra line).
String? sessionStartHint({
  required String viewDate,
  required String today,
  required int nowMin,
  required int slot,
  required bool someoneCheckedIn,
  bool alreadyLive = false,
}) {
  if (viewDate.compareTo(today) < 0) return null;
  if (sessionMayStart(
    viewDate: viewDate,
    today: today,
    nowMin: nowMin,
    slot: slot,
    someoneCheckedIn: someoneCheckedIn,
    alreadyLive: alreadyLive,
  )) {
    return null;
  }
  return "Can be started at ${fmtSlot(slot)}, or as soon as someone checks in";
}

/// A new start is blocked once this coach already has [kMaxConcurrentLiveSessions]
/// running. Rejoining one of those does not count as another.
bool startingAnotherLiveSessionIsBlocked({
  required int liveCount,
  required bool alreadyLive,
}) =>
    !alreadyLive && liveCount >= kMaxConcurrentLiveSessions;
