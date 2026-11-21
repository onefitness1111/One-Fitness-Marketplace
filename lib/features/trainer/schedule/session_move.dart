/// Whether a drag-and-drop on the Schedule screen is allowed, decided before
/// anything is written.
///
/// Kept apart from the widgets because a move is mostly rules, not gesture:
/// the same question ("can this land here?") has to be answered while a
/// finger is still hovering — to tint the card — and again on release, before
/// the writes start. One pure function answers both, and can be tested
/// without pumping a widget.
///
/// Every refusal here is also enforced by the database. `enforce_booking_limits`
/// is a BEFORE INSERT trigger, and both moves below are written as
/// insert-then-delete for exactly that reason: the server still gets to
/// refuse, and a refused insert leaves the original booking where it was. These
/// checks exist to say *why* in a sentence a coach can act on, not to be the
/// only thing standing in the way. A coach overlap uses the same hour as the
/// trigger ([kTrainerOverlapMinutes]): starts under 60 minutes apart, excluding
/// the shared session being joined. An owner is allowed through after they
/// confirm, because the trigger accepts an insert with `overridden_by` set.
library;

import "../../../core/utils/booking_limits.dart";
import "../../../core/utils/scheduling_utils.dart";
import "../../../data/models/booking.dart";

sealed class MoveCheck {
  const MoveCheck();
}

/// Dropped back where it started. Not an error, and nothing to say about it.
class MoveNoop extends MoveCheck {
  const MoveNoop();
}

/// Can't be done, with the sentence to show the coach.
class MoveRefused extends MoveCheck {
  const MoveRefused(this.reason);

  final String reason;
}

/// Go ahead. [overBy] above zero means the target ends up past its class
/// limit — allowed, because staff know the room, but never silently: the
/// caller confirms first. Only ever set for an owner; a coach gets a
/// [MoveRefused] instead, since the database would refuse their insert.
class MoveAllowed extends MoveCheck {
  const MoveAllowed({
    required this.count,
    required this.cap,
    this.overBy = 0,
    this.conflict,
  });

  /// What the target session holds now, before the move.
  final int count;
  final int cap;
  final int overBy;

  /// Another session this coach is already running within the hour.
  /// Set only for an owner, who can book over it. A coach is refused first.
  final Booking? conflict;

  bool get needsCapacityOverride => overBy > 0;
  bool get needsOverride => needsCapacityOverride || conflict != null;
}

/// Bookings that still hold a seat. A cancelled one occupies nothing, and
/// counting it would make a half-empty class look full.
List<Booking> _live(List<Booking> all) =>
    all.where((b) => b.status != "cancelled").toList();

/// Any booking of [clientId]'s that overlaps [date] at [slot], ignoring the
/// ones listed in [ignoreIds] and anything belonging to [exceptTrainerId] at
/// that exact slot — that last one is the session being dropped onto, which
/// callers report separately and more precisely.
Booking? _clientClash(
  List<Booking> live,
  String clientId,
  String date,
  int slot, {
  required Set<String> ignoreIds,
  String? exceptTrainerId,
}) {
  final clashes = live.where(
    (b) =>
        b.clientId == clientId &&
        b.date == date &&
        !ignoreIds.contains(b.id) &&
        !(b.trainerId == exceptTrainerId && b.slot == slot) &&
        (b.slot - slot).abs() < kTrainerOverlapMinutes,
  );
  return clashes.isEmpty ? null : clashes.first;
}

/// Moving one client out of their session and into another one.
///
/// [toSessionType] and [toDiscipline] describe the target, which may differ
/// from what [booking] was for — dropping someone from a semi-private into a
/// large group is a legitimate thing to want. The caller re-picks the plan to
/// charge when they differ.
MoveCheck checkClientMove({
  required List<Booking> all,
  required Booking booking,
  required String toTrainerId,
  required String toDate,
  required int toSlot,
  required String toSessionType,
  required String toDiscipline,
  required bool isOwner,
  required String clientName,
  int semiPrivateCap = 4,
}) {
  if (booking.trainerId == toTrainerId &&
      booking.date == toDate &&
      booking.slot == toSlot) {
    return const MoveNoop();
  }

  final live = _live(all);
  final target = sessionGroup(live, toTrainerId, toDate, toSlot);

  if (target.any((b) => b.clientId == booking.clientId)) {
    return MoveRefused("$clientName is already in that session.");
  }

  // Same rule as the database: this coach already has a session starting
  // within the hour, and it isn't the shared session being joined. The
  // booking being moved doesn't count — a 30-minute slide of the only
  // person in it is not a clash with itself. Anyone staying behind does.
  final conflict = findTrainerConflict(
    live.where((b) => b.id != booking.id).toList(),
    toTrainerId,
    toDate,
    toSlot,
    toSessionType,
    toDiscipline,
  );
  if (conflict != null && !isOwner) {
    return const MoveRefused(coachOverlapRefusal);
  }

  // The client's own diary. Being double-booked with two coaches at once is
  // the one clash the target session's own capacity can't catch. An owner
  // override covers the coach's schedule, not this.
  final clash = _clientClash(
    live,
    booking.clientId,
    toDate,
    toSlot,
    ignoreIds: {booking.id},
    exceptTrainerId: toTrainerId,
  );
  if (clash != null) {
    return MoveRefused(
      "$clientName already has a session at ${_hhmm(clash.slot)} that day.",
    );
  }

  if (conflict != null) {
    final cap = capFor(toSessionType, semiPrivateCap: semiPrivateCap);
    return MoveAllowed(count: target.length, cap: cap, conflict: conflict);
  }

  final cap = capFor(toSessionType, semiPrivateCap: semiPrivateCap);
  if (target.length >= cap) {
    if (!isOwner) {
      return MoveRefused(
        "That session is at its limit of $cap — only the owner can move someone in past it.",
      );
    }
    return MoveAllowed(
      count: target.length,
      cap: cap,
      overBy: target.length + 1 - cap,
    );
  }
  return MoveAllowed(count: target.length, cap: cap);
}

/// Moving a whole session — every client in it — to another date, keeping the
/// same coach and the same time.
MoveCheck checkSessionMove({
  required List<Booking> all,
  required List<Booking> group,
  required String toDate,
  required String today,
  required bool isOwner,
  int semiPrivateCap = 4,
}) {
  if (group.isEmpty)
    return const MoveRefused("There's nothing in that session to move.");
  final first = group.first;
  if (toDate == first.date) return const MoveNoop();
  if (toDate.compareTo(today) < 0) {
    return const MoveRefused("A session can't be moved into the past.");
  }

  final movingIds = {for (final b in group) b.id};
  // The group itself is on the old date, so it can't be part of what the new
  // date already holds — but filtering by id keeps that true even if a
  // caller hands in a group that overlaps the target.
  final live = _live(all).where((b) => !movingIds.contains(b.id)).toList();
  final target = sessionGroup(live, first.trainerId, toDate, first.slot);

  final dayConflict = findTrainerConflict(
    live,
    first.trainerId,
    toDate,
    first.slot,
    first.sessionType,
    first.discipline,
  );
  if (dayConflict != null && !isOwner) {
    return const MoveRefused(coachOverlapRefusal);
  }

  for (final b in group) {
    final clash = _clientClash(
      live,
      b.clientId,
      toDate,
      first.slot,
      ignoreIds: movingIds,
      exceptTrainerId: first.trainerId,
    );
    if (clash != null) {
      return const MoveRefused(
        "Someone in this session is already booked at that time on that day.",
      );
    }
  }

  final cap = capFor(first.sessionType, semiPrivateCap: semiPrivateCap);
  if (dayConflict != null) {
    return MoveAllowed(count: target.length, cap: cap, conflict: dayConflict);
  }
  final after = target.length + group.length;
  if (after > cap) {
    if (!isOwner) {
      return MoveRefused(
        "That day's ${_hhmm(first.slot)} slot only takes $cap — moving ${group.length} there would make it $after.",
      );
    }
    return MoveAllowed(count: target.length, cap: cap, overBy: after - cap);
  }
  return MoveAllowed(count: target.length, cap: cap);
}

/// Bare "9:30"/"14:00" for the middle of a sentence, where [fmtSlot]'s
/// "9:30 AM" reads as shouting.
String _hhmm(int minutes) =>
    "${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}";
