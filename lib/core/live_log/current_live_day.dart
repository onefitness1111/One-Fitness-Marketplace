/// Start-of-day marker rows in live_set_logs. These are not real sets.
const liveDayStartedCoachMarker = "__day_started_coach__";
const liveDayStartedClientMarker = "__day_started_client__";
const liveDayStartMarkers = [liveDayStartedCoachMarker, liveDayStartedClientMarker];

/// One row of "this program day is the live session".
///
/// An unfinished set log is not a row. Logging a day and marking it live
/// are different: the log can stay open after the live session ends.
class LiveDayRun {
  const LiveDayRun({
    required this.clientId,
    required this.dayId,
    required this.startedAt,
    this.endedAt,
    this.lastActivityAt,
    this.startedRole,
  });

  final String clientId;
  final String dayId;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// Newest set change on this day (live_set_logs.updated_at), if known.
  final DateTime? lastActivityAt;

  /// client | coach | owner, when the row was read with it.
  final String? startedRole;

  bool get isOpen => endedAt == null;

  /// The later of the start and the newest set change.
  DateTime get lastSeenAt {
    final last = lastActivityAt;
    return last != null && last.isAfter(startedAt) ? last : startedAt;
  }
}

/// A live day with nothing logged for this long stops counting as live.
/// The server closes these rows on a schedule as well
/// (close_stale_live_days); this keeps the app right in between.
const Duration liveDayIdleLimit = Duration(hours: 3);

/// True when nothing has happened on [run] for [liveDayIdleLimit].
bool isLiveDayStale(LiveDayRun run, DateTime now) =>
    now.toUtc().difference(run.lastSeenAt.toUtc()) >= liveDayIdleLimit;

/// The one day that should show "Live now" for each client.
///
/// Several open rows can exist (an older day was never closed). Only the
/// newest open row counts. Ended rows never count. Clients with nothing
/// open are absent. When [now] is given, a day with no activity for
/// [liveDayIdleLimit] is treated as over.
Map<String, String> currentLiveDayByClient(Iterable<LiveDayRun> runs, {DateTime? now}) {
  final newest = <String, LiveDayRun>{};
  for (final run in runs) {
    if (!run.isOpen || run.dayId.isEmpty || run.clientId.isEmpty) continue;
    if (now != null && isLiveDayStale(run, now)) continue;
    final have = newest[run.clientId];
    if (have == null || run.startedAt.isAfter(have.startedAt)) {
      newest[run.clientId] = run;
    }
  }
  return {for (final e in newest.entries) e.key: e.value.dayId};
}

/// Starting [dayId] closes every other open day for that client.
/// The new day is the only one left open. Set logs are not in this list.
List<LiveDayRun> replaceLiveDay({
  required List<LiveDayRun> openRuns,
  required String clientId,
  required String dayId,
  required DateTime at,
}) {
  final ended = at;
  return [
    for (final run in openRuns)
      if (run.clientId == clientId && run.dayId != dayId) LiveDayRun(
        clientId: run.clientId,
        dayId: run.dayId,
        startedAt: run.startedAt,
        endedAt: ended,
      ) else run,
    LiveDayRun(clientId: clientId, dayId: dayId, startedAt: at),
  ];
}

/// Ending the live session closes every open day. Nothing stays joinable.
List<LiveDayRun> endLiveDays(List<LiveDayRun> runs, {required String clientId, required DateTime at}) {
  return [
    for (final run in runs)
      if (run.clientId == clientId && run.isOpen)
        LiveDayRun(clientId: run.clientId, dayId: run.dayId, startedAt: run.startedAt, endedAt: at)
      else
        run,
  ];
}
