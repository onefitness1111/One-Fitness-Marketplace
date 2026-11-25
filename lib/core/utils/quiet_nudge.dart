import "../../data/models/booking.dart";
import "../../data/models/client_record.dart";
import "../../data/models/quiet_nudge.dart";
import "attention_utils.dart";

/// What the morning job does for one quiet streak.
///
/// Day 0 and day 1 do nothing, and they clear anything already sent.
/// Day 2 sends one phone notification. Day 3, if that notification already
/// went and they are still quiet, sends one text and alerts staff. A later
/// day does not send either one again. If the job missed day 2, the next
/// run sends the phone notification first and waits for the following
/// morning to send the text.
enum NudgeStep { rest, push, textAndAlert, none }

int quietDaysBetween(DateTime today, DateTime lastActivity) {
  final start = DateTime(
    lastActivity.year,
    lastActivity.month,
    lastActivity.day,
  );
  final end = DateTime(today.year, today.month, today.day);
  return end.difference(start).inDays;
}

NudgeStep quietNudgeStep({
  required int quietDays,
  required bool pushAlreadySent,
  required bool textAlreadySent,
}) {
  if (quietDays < 2) return NudgeStep.rest;
  if (!pushAlreadySent) return NudgeStep.push;
  if (quietDays >= 3 && !textAlreadySent) return NudgeStep.textAndAlert;
  return NudgeStep.none;
}

/// A quiet-streak text goes out only with consent on file, a phone number,
/// and no opt-out. Push is a separate choice and is not decided here.
bool mayTextQuietClient({
  required bool smsOptIn,
  required bool marketingOptOut,
  required bool hasConsentRecord,
  required bool hasPhone,
}) {
  return smsOptIn && !marketingOptOut && hasConsentRecord && hasPhone;
}

/// The latest day (yyyy-MM-dd) with a real food line or a logged set.
String? lastLoggedDay(ClientRecord record) {
  String? best;
  void keep(String day) {
    if (day.length < 10) return;
    final key = day.substring(0, 10);
    if (best == null || key.compareTo(best!) > 0) best = key;
  }

  for (final day in record.foodLog.days.entries) {
    final hasLine = day.value.values.any((lines) => lines.isNotEmpty);
    if (hasLine) keep(day.key);
  }
  for (final log in record.workoutLogs) {
    final didWork = log.exercises.any(
      (exercise) => exercise.sets.any(
        (set) =>
            set.completed ||
            (set.completedReps ?? 0) > 0 ||
            (set.completedWeight ?? 0) > 0,
      ),
    );
    if (didWork) keep(log.date);
  }
  return best;
}

/// True once the client has logged something after the streak the job saw.
bool loggedSince(ClientRecord record, String lastActivityOn) {
  final latest = lastLoggedDay(record);
  if (latest == null) return false;
  return latest.compareTo(lastActivityOn) > 0;
}

/// The in-app "Hasn't logged lately" line. It stays until the client logs
/// again. The owner sees every open alert. A coach sees one only when that
/// client is booked with them in the next 7 days ([clientsBookedWithCoachSoon]),
/// never based on [QuietNudge.coachId] or a primary coach.
List<AttentionItem> quietClientAttention({
  required List<QuietNudge> nudges,
  required Map<String, ClientRecord> records,
  required Set<String> rosterIds,
  required bool isOwner,
  required String? viewerId,
  required List<Booking> bookings,
  DateTime? now,
}) {
  if (!isOwner && (viewerId == null || viewerId.isEmpty)) return const [];
  final soonIds = isOwner ? null : clientsBookedWithCoachSoon(bookings, viewerId!, now: now);
  final items = <AttentionItem>[];
  for (final nudge in nudges) {
    if (!nudge.staffAlertOpen) continue;
    if (!rosterIds.contains(nudge.clientId)) continue;
    if (!isOwner && !soonIds!.contains(nudge.clientId)) continue;
    final record = records[nudge.clientId];
    if (record != null && loggedSince(record, nudge.lastActivityOn)) continue;
    items.add(
      AttentionItem(
        clientId: nudge.clientId,
        key: "quiet-3-days",
        label: "Hasn't logged lately",
      ),
    );
  }
  return items;
}
