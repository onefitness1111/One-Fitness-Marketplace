import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:supabase_flutter/supabase_flutter.dart";

import "../../core/live_log/current_live_day.dart";
import "../../core/supabase/supabase_service.dart";
import "../../core/utils/date_utils.dart";
import "../models/live_session.dart";

/// Every session currently running, as far as this signed-in user is allowed
/// to see. RLS already narrows it: a coach sees their own, a client sees only
/// sessions they're booked into.
///
/// Kept as a list rather than a single value because a coach can have a
/// session running while also appearing in another's roster, and because the
/// realtime stream delivers whole rows either way.
class LiveSessionsNotifier extends Notifier<List<LiveSession>> {
  @override
  List<LiveSession> build() => const [];

  void setAll(List<LiveSession> next) => state = next;

  /// Applies one realtime row. Ending a session is an update, not a delete,
  /// so a row arriving with ended_at set has to remove it from the live list
  /// rather than be merged in — otherwise Beep Your Coach would stay switched
  /// on after the coach finished.
  void apply(LiveSession run) {
    final without = state.where((r) => r.id != run.id).toList();
    state = run.isLive ? [...without, run] : without;
  }

  void remove(String id) => state = state.where((r) => r.id != id).toList();

  /// The running session this client can beep in.
  ///
  /// Takes no client id on purpose: the policies on `session_runs` already
  /// decide that, returning only sessions the signed-in person is booked
  /// into. Re-filtering here by a locally-held id would be a second,
  /// weaker copy of a rule the database already enforces — and the one that
  /// would be wrong if they ever disagreed.
  LiveSession? get beepable {
    for (final r in state) {
      if (r.supportsBeep) return r;
    }
    return null;
  }
}

final liveSessionsProvider =
    NotifierProvider<LiveSessionsNotifier, List<LiveSession>>(LiveSessionsNotifier.new);

/// A program day a coach started for a client. Beep Your Coach follows this,
/// not the booked clock by itself.
class CoachLedDay {
  const CoachLedDay({required this.clientId, required this.dayId, this.trainerId});
  final String clientId;
  final String dayId;
  final String? trainerId;

  /// Used only when there is no booked session_run to attach the beep to.
  String get fallbackRunId => "day-$clientId-$dayId";
}

class CoachLedDaysNotifier extends Notifier<List<CoachLedDay>> {
  @override
  List<CoachLedDay> build() => const [];

  void setAll(List<CoachLedDay> next) => state = next;

  CoachLedDay? forClient(String clientId) {
    for (final day in state) {
      if (day.clientId == clientId) return day;
    }
    return null;
  }
}

final coachLedDaysProvider =
    NotifierProvider<CoachLedDaysNotifier, List<CoachLedDay>>(CoachLedDaysNotifier.new);

Future<List<dynamic>> _coachLedRows(Future<dynamic> query) async {
  try {
    final rows = await query;
    return rows is List ? rows : const [];
  } catch (_) {
    return const [];
  }
}

String _isoDateValue(dynamic raw) {
  final value = raw?.toString() ?? "";
  return value.length >= 10 ? value.substring(0, 10) : value;
}

/// Builds the coach-led list the client bar uses.
///
/// An open coach/owner live_day_runs row still counts. A leftover
/// `__day_started_coach__` marker does not, unless it is for today
/// (Pacific) and its matching live-day run is still open. A marker
/// from an earlier date, or one whose run was already closed, cannot
/// keep the bar on the screen.
List<CoachLedDay> coachLedDaysFromRows({
  required List<Map<String, dynamic>> openRuns,
  required List<Map<String, dynamic>> openCoachMarkers,
  required String todayPacific,
}) {
  final found = <String, CoachLedDay>{};
  final openKeys = <String>{};
  for (final row in openRuns) {
    final clientId = row["client_id"]?.toString() ?? "";
    final dayId = row["day_id"]?.toString() ?? "";
    final logDate = _isoDateValue(row["log_date"]);
    if (clientId.isEmpty || dayId.isEmpty) continue;
    if (logDate.isNotEmpty) openKeys.add("$clientId|$logDate|$dayId");
    final role = row["started_role"]?.toString();
    if (role != "coach" && role != "owner") continue;
    found[clientId] = CoachLedDay(
      clientId: clientId,
      dayId: dayId,
      trainerId: row["trainer_id"]?.toString(),
    );
  }
  for (final row in openCoachMarkers) {
    final clientId = row["client_id"]?.toString() ?? "";
    final dayId = row["day_id"]?.toString() ?? "";
    final logDate = _isoDateValue(row["log_date"]);
    if (clientId.isEmpty || dayId.isEmpty || found.containsKey(clientId)) continue;
    if (logDate.isEmpty || logDate.compareTo(todayPacific) < 0) continue;
    // A marker only counts when its own run is still open. A closed
    // (or missing) run must not keep the "coach is live" bar up.
    if (!openKeys.contains("$clientId|$logDate|$dayId")) continue;
    found[clientId] = CoachLedDay(clientId: clientId, dayId: dayId);
  }
  return found.values.toList();
}

Future<List<CoachLedDay>> loadCoachLedDays() async {
  final today = isoTodayPacific();
  final both = await Future.wait([
    _coachLedRows(
      SupabaseService.client
          .from("live_day_runs")
          .select("client_id, day_id, started_role, trainer_id, ended_at, log_date")
          .isFilter("ended_at", null),
    ),
    _coachLedRows(
      SupabaseService.client
          .from("live_set_logs")
          .select("client_id, day_id, exercise_name, ended_at, log_date")
          .eq("exercise_name", liveDayStartedCoachMarker)
          .isFilter("ended_at", null),
    ),
  ]);
  return coachLedDaysFromRows(
    openRuns: [
      for (final raw in both[0]) (raw as Map).cast<String, dynamic>(),
    ],
    openCoachMarkers: [
      for (final raw in both[1]) (raw as Map).cast<String, dynamic>(),
    ],
    todayPacific: today,
  );
}

/// Beeps for whichever session is currently on screen.
///
/// Scoped to one run rather than held globally: a coach only ever looks at
/// the session they're running, and a client only at their own, so there's
/// nothing to gain from keeping yesterday's beeps around.
class BeepsNotifier extends Notifier<List<Beep>> {
  @override
  List<Beep> build() => const [];

  void setAll(List<Beep> next) => state = next;

  void apply(Beep beep) {
    final without = state.where((b) => b.id != beep.id).toList();
    // A cancelled beep is gone from both sides — the spec is explicit that
    // cancelling clears it on the coach's side too.
    state = beep.isCancelled ? without : [...without, beep];
  }

  void clear() => state = const [];

  /// What the coach still has to answer, in the order they should see it:
  /// oldest first, except a Spot always jumps to the top.
  List<Beep> openFor(String trainerId) {
    final open = state.where((b) => b.trainerId == trainerId && b.isOpen).toList()
      ..sort(compareBeepPriority);
    return open;
  }

  /// This client's own beeps that are still standing, newest first — what
  /// they see as "Coach is coming" or "Coach notified", and can cancel.
  List<Beep> mineFor(String clientId) {
    final mine = state.where((b) => b.clientId == clientId && !b.isCancelled).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return mine;
  }
}

final beepsProvider = NotifierProvider<BeepsNotifier, List<Beep>>(BeepsNotifier.new);

/// Subscribes to both tables for as long as someone is signed in.
///
/// Realtime rather than push is the primary path on purpose: the spec wants
/// alerts to arrive instantly and an unacknowledged Spot to re-buzz every ten
/// seconds, and push can promise neither. The coach has the session screen
/// open by definition — they just started it.
class BeepRealtime {
  BeepRealtime(this._ref);
  final Ref _ref;

  RealtimeChannel? _runsChannel;
  RealtimeChannel? _beepsChannel;
  RealtimeChannel? _daysChannel;

  Future<void> start() async {
    await stop();
    final sessionsF = SupabaseService.loadLiveSessions();
    final daysF = loadCoachLedDays();
    try {
      _ref.read(liveSessionsProvider.notifier).setAll(await sessionsF);
    } catch (_) {
      // A failed first load is not fatal — the subscriptions below still
      // deliver anything that changes from here on.
    }
    try {
      _ref.read(coachLedDaysProvider.notifier).setAll(await daysF);
    } catch (_) {}

    _runsChannel = SupabaseService.client
        .channel("session_runs_live")
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: "public",
          table: "session_runs",
          callback: (payload) {
            final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
            if (row.isEmpty) return;
            final run = LiveSession.fromJson(row);
            if (run == null) return;
            if (payload.eventType == PostgresChangeEvent.delete) {
              _ref.read(liveSessionsProvider.notifier).remove(run.id);
            } else {
              _ref.read(liveSessionsProvider.notifier).apply(run);
            }
          },
        )
        .subscribe();

    Future<void> reloadDays() async {
      _ref.read(coachLedDaysProvider.notifier).setAll(await loadCoachLedDays());
    }

    _daysChannel = SupabaseService.client
        .channel("live_days_${DateTime.now().microsecondsSinceEpoch}")
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: "public",
          table: "live_set_logs",
          callback: (_) async {
            await reloadDays();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: "public",
          table: "live_day_runs",
          callback: (_) async {
            await reloadDays();
          },
        )
        .subscribe();

    _beepsChannel = SupabaseService.client
        .channel("beeps_live")
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: "public",
          table: "beeps",
          callback: (payload) {
            final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
            if (row.isEmpty) return;
            final beep = Beep.fromJson(row);
            if (beep == null) return;
            _ref.read(beepsProvider.notifier).apply(beep);
          },
        )
        .subscribe();
  }

  Future<void> stop() async {
    final runs = _runsChannel;
    final beeps = _beepsChannel;
    final days = _daysChannel;
    _runsChannel = null;
    _beepsChannel = null;
    _daysChannel = null;
    if (runs != null) await SupabaseService.client.removeChannel(runs);
    if (beeps != null) await SupabaseService.client.removeChannel(beeps);
    if (days != null) await SupabaseService.client.removeChannel(days);
  }
}

final beepRealtimeProvider = Provider<BeepRealtime>((ref) {
  final rt = BeepRealtime(ref);
  ref.onDispose(rt.stop);
  return rt;
});
