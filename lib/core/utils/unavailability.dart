import "../../data/models/booking.dart";
import "../../data/models/trainer.dart";
import "date_utils.dart";
import "domain_labels.dart";
import "membership_utils.dart";

/// Minutes in a day. A "from this time" block runs until here.
const kEndOfDayMin = 24 * 60;

/// What the coach's message starts as. They can edit it before saving.
const kDefaultClientNote =
    "I'm sorry — I need to cancel our session. It's back on your plan, so please book another time that works for you.";

/// How long a reason and a note to clients are allowed to be.
const kUnavailabilityReasonMax = 80;
const kUnavailabilityNoteMax = 500;

bool dateInUnavailability(TrainerUnavailability u, String date) =>
    date.compareTo(u.startDate) >= 0 && date.compareTo(u.endDate) <= 0;

/// True when a session starting at [slot] and running [sessionLen] minutes
/// overlaps this block on [date]. All-day and legacy rows cover the day.
/// A partial block only overlaps its minutes, and those minutes apply on
/// every day from the start date through the end date.
bool unavailabilityOverlapsSlot(
  TrainerUnavailability u,
  String date,
  int slot, {
  int sessionLen = 60,
}) {
  if (!dateInUnavailability(u, date)) return false;
  if (u.blocksWholeDay) return true;
  final start = u.startMin ?? 0;
  final end = u.endMin ?? kEndOfDayMin;
  final slotEnd = slot + sessionLen;
  return start < slotEnd && end > slot;
}

/// Sessions this block would cancel. A checked-in or no-show session was
/// already used, so it stays. An early or late cancel already gave the
/// session back. Every other overlapping booking for this coach is in,
/// including every client in a semi-private session.
List<Booking> bookingsHitByUnavailability(
  TrainerUnavailability u,
  List<Booking> bookings, {
  String? trainerId,
}) {
  return bookings.where((b) {
    if (trainerId != null && b.trainerId != trainerId) return false;
    if (b.status == "cancelled") return false;
    if (sessionIsConsumed(b.attendanceStatus)) return false;
    if (kGiveBackAttendanceStatuses.contains(b.attendanceStatus)) return false;
    return unavailabilityOverlapsSlot(u, b.date, b.slot, sessionLen: b.durationMin);
  }).toList();
}

/// One row in the preview: one time slot, and how many clients are in it.
class AffectedSession {
  const AffectedSession({
    required this.date,
    required this.slot,
    required this.sessionType,
    required this.clientIds,
    required this.bookingIds,
  });

  final String date;
  final int slot;
  final String sessionType;
  final List<String> clientIds;
  final List<String> bookingIds;

  int get clients => clientIds.length;

  String get line {
    final people = clients == 1 ? "1 client" : "$clients clients";
    return "${niceDate(date)} · ${fmtSlot(slot)} · ${sessionTypeLabel(sessionType)} · $people";
  }
}

List<AffectedSession> affectedSessionsFor(
  TrainerUnavailability u,
  List<Booking> bookings, {
  String? trainerId,
}) {
  final groups = <String, List<Booking>>{};
  for (final b in bookingsHitByUnavailability(u, bookings, trainerId: trainerId)) {
    groups.putIfAbsent("${b.date}|${b.slot}|${b.sessionType}", () => []).add(b);
  }
  final sessions = groups.values.map((rows) {
    final first = rows.first;
    return AffectedSession(
      date: first.date,
      slot: first.slot,
      sessionType: first.sessionType,
      clientIds: rows.map((b) => b.clientId).toList(),
      bookingIds: rows.map((b) => b.id).toList(),
    );
  }).toList();
  sessions.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    return a.slot.compareTo(b.slot);
  });
  return sessions;
}

String unavailabilityRangeLabel(TrainerUnavailability u) =>
    u.startDate == u.endDate ? niceDate(u.startDate) : "${niceDate(u.startDate)} – ${niceDate(u.endDate)}";

/// "All day", "From 2:00 PM", or "2:00 PM–4:00 PM". For the coach's own list.
String unavailabilityStaffTime(TrainerUnavailability u) {
  if (u.blocksWholeDay) return "All day";
  if (u.endMin == null) return "From ${fmtSlot(u.startMin ?? 0)}";
  return "${fmtSlot(u.startMin ?? 0)}–${fmtSlot(u.endMin!)}";
}

/// What a client sees. Reason and the date range only — never a legal name.
String clientUnavailabilityText(TrainerUnavailability u) {
  final reason = u.displayReason;
  final head = reason.isEmpty ? "Unavailable" : "Unavailable · $reason";
  final range = unavailabilityRangeLabel(u);
  if (u.blocksWholeDay) return "$head · $range";
  if (u.endMin == null) return "$head · $range, from ${fmtSlot(u.startMin ?? 0)}";
  return "$head · $range, ${fmtSlot(u.startMin ?? 0)}–${fmtSlot(u.endMin!)}";
}

/// Lines for every block covering [date]. Null when that day is clear.
String? clientUnavailabilityLine(Trainer trainer, String date) {
  final hits = trainer.unavailability.where((u) => dateInUnavailability(u, date)).toList()
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  if (hits.isEmpty) return null;
  return hits.map(clientUnavailabilityText).join("\n");
}

/// Blocks a client should still be told about: today or later.
List<TrainerUnavailability> upcomingUnavailability(Trainer trainer, String today) {
  final hits = trainer.unavailability.where((u) => u.endDate.compareTo(today) >= 0).toList()
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  return hits;
}
