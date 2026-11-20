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
  });

  final String clientId;
  final String dayId;
  final DateTime startedAt;
  final DateTime? endedAt;

  bool get isOpen => endedAt == null;
}

/// The one day that should show "Live now" for each client.
///
/// Several open rows can exist (an older day was never closed). Only the
/// newest open row counts. Ended rows never count. Clients with nothing
/// open are absent.
Map<String, String> currentLiveDayByClient(Iterable<LiveDayRun> runs) {
  final newest = <String, LiveDayRun>{};
  for (final run in runs) {
    if (!run.isOpen || run.dayId.isEmpty || run.clientId.isEmpty) continue;
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
