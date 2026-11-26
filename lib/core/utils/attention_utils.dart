import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/client_record.dart";
import "date_utils.dart";

/// One row in the coach dashboard's "Needs Attention" list.
class AttentionItem {
  const AttentionItem({required this.clientId, required this.key, required this.label, this.bookingId, this.date, this.slot});
  final String clientId;
  final String key;
  final String label;
  final String? bookingId;
  final String? date;
  final int? slot;
}

/// Mirrors attentionHelpers.js `computeNeedsAttention` — every roster
/// client this coach programs for who's missing an active workout and/or
/// nutrition program.
List<AttentionItem> computeNeedsAttention(List<ClientInfo> myRoster, Map<String, ClientRecord> clientRecords) {
  final out = <AttentionItem>[];
  for (final c in myRoster) {
    final rec = clientRecords[c.id];
    final hasProgram = rec?.savedPrograms.any((p) => p.status == "active") ?? false;
    final hasNutrition = rec?.nutrition != null;
    if (!hasProgram) out.add(AttentionItem(clientId: c.id, key: "no-program", label: "No workout program"));
    if (!hasNutrition) out.add(AttentionItem(clientId: c.id, key: "no-nutrition", label: "No nutrition program"));
  }
  return out;
}

/// How far ahead a coach's "needs a program" list looks: clients booked
/// with that coach in the next 7 days.
const needsProgramLookaheadDays = 7;

/// Clients with a session with [coachId] (as the session's trainer) that
/// hasn't ended yet and starts within the next [needsProgramLookaheadDays]
/// days, in the gym's local time. Cancelled sessions don't count. Based
/// only on bookings, never on a primary coach or any assignment.
Set<String> clientsBookedWithCoachSoon(Iterable<Booking> bookings, String coachId, {DateTime? now}) {
  final wallNow = pacificWallNow(now);
  final until = DateTime(wallNow.year, wallNow.month, wallNow.day + needsProgramLookaheadDays,
      wallNow.hour, wallNow.minute, wallNow.second);
  final out = <String>{};
  for (final b in bookings) {
    if (b.trainerId != coachId || b.clientId.isEmpty) continue;
    if (b.status == "cancelled" || (b.attendanceStatus ?? "").contains("cancel")) continue;
    final day = DateTime.tryParse(b.date);
    if (day == null) continue;
    final start = DateTime(day.year, day.month, day.day, 0, b.slot);
    final end = DateTime(day.year, day.month, day.day, 0, b.slot + (b.durationMin > 0 ? b.durationMin : 60));
    if (end.isAfter(wallNow) && !start.isAfter(until)) out.add(b.clientId);
  }
  return out;
}

/// Who the "No workout program" / "No nutrition program" / program-update
/// rows are about. The owner sees everyone. A coach sees only clients
/// booked with them in the next 7 days ([clientsBookedWithCoachSoon]).
List<ClientInfo> needsProgramRoster({
  required List<ClientInfo> roster,
  required List<Booking> bookings,
  required bool isOwner,
  required String? coachId,
  DateTime? now,
}) {
  if (isOwner) return roster;
  if (coachId == null || coachId.isEmpty) return const [];
  final ids = clientsBookedWithCoachSoon(bookings, coachId, now: now);
  return roster.where((c) => ids.contains(c.id)).toList();
}

/// Mirrors attentionHelpers.js `computeUnloggedAttendance` — past-or-today
/// sessions the coach never marked an outcome for.
List<AttentionItem> computeUnloggedAttendance(List<ClientInfo> myRoster, List<Booking> bookings) {
  final rosterIds = myRoster.map((c) => c.id).toSet();
  final today = isoToday();
  final matches = bookings.where((b) => rosterIds.contains(b.clientId) && b.attendanceStatus == null && b.date.compareTo(today) <= 0).toList()
    ..sort((a, b) => a.date == b.date ? a.slot.compareTo(b.slot) : a.date.compareTo(b.date));
  return matches
      .map((b) => AttentionItem(clientId: b.clientId, key: "no-attendance", label: "No attendance logged", bookingId: b.id, date: b.date, slot: b.slot))
      .toList();
}

/// One-time alert for a coach: a client just signed up using their Coach
/// Code. Fires once per referred client — clears (SupabaseService.
/// markCoachCodeAlertSeen) the first time the coach opens that client's
/// profile from this row (mirrors Coaches Overview's `reviewedByOwner`
/// pattern — see coaches_overview_screen.dart).
List<AttentionItem> computeCoachCodeAlerts(List<ClientInfo> myRoster) => myRoster
    .where((c) => c.referredByTrainerId != null && !c.coachCodeAlertSeen)
    .map((c) => AttentionItem(clientId: c.id, key: "coach-code-used", label: "Coach Code"))
    .toList();

/// "No attendance logged" and "Coach Code" rows for whoever is looking.
///
/// The owner sees every client: unlogged sessions for every coach, and every
/// unseen Coach Code signup. A coach sees only clients booked with them in
/// the next 7 days ([clientsBookedWithCoachSoon]), same as the program and
/// quiet-client rows: their own unlogged sessions with those clients, and
/// Coach Code signups with their code among those clients. Based only on
/// bookings, never on a primary coach or any assignment.
List<AttentionItem> bookingAttentionForViewer({
  required List<ClientInfo> roster,
  required List<Booking> bookings,
  required bool isOwner,
  required String? coachId,
  DateTime? now,
}) {
  if (isOwner) {
    return [
      ...computeUnloggedAttendance(roster, bookings),
      ...computeCoachCodeAlerts(roster),
    ];
  }
  if (coachId == null || coachId.isEmpty) return const [];
  final soon = needsProgramRoster(roster: roster, bookings: bookings, isOwner: false, coachId: coachId, now: now);
  final mine = bookings.where((b) => b.trainerId == coachId).toList();
  return [
    ...computeUnloggedAttendance(soon, mine),
    ...computeCoachCodeAlerts(soon.where((c) => c.referredByTrainerId == coachId).toList()),
  ];
}
