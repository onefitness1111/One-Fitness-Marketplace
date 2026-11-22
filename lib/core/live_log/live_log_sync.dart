import "dart:async";
import "dart:convert";
import "package:flutter/foundation.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "package:uuid/uuid.dart";
import "../supabase/supabase_service.dart";
import "current_live_day.dart";

/// One set's live values. Reps and weight each carry the time they were last
/// changed, so the two fields merge independently and the newest edit wins.
class LiveSetValue {
  LiveSetValue({this.reps, this.repsAt, this.weight, this.weightAt});
  int? reps;
  DateTime? repsAt;
  double? weight;
  DateTime? weightAt;
}

class LiveNote {
  const LiveNote({
    required this.id,
    required this.exercise,
    required this.authorId,
    required this.authorName,
    required this.authorRole,
    required this.body,
    required this.createdAt,
  });
  final String id;
  final String exercise;
  final String authorId;
  final String authorName;
  final String authorRole;
  final String body;
  final DateTime createdAt;
}

/// A newer value for the same set field replaces the one still waiting.
/// A different set, or the other field, is kept. Nothing is added twice.
List<Map<String, dynamic>> queueLiveLogOp(List<Map<String, dynamic>> waiting, Map<String, dynamic> op) {
  final next = [for (final item in waiting) Map<String, dynamic>.from(item)];
  if (op["t"] == "set") {
    next.removeWhere((o) =>
        o["t"] == "set" &&
        o["client"] == op["client"] &&
        o["date"] == op["date"] &&
        o["day"] == op["day"] &&
        o["exercise"] == op["exercise"] &&
        o["set"] == op["set"] &&
        o["field"] == op["field"]);
  }
  next.add(Map<String, dynamic>.from(op));
  return next;
}

/// Entries waiting to reach the server. Persisted on the phone, so a dropped
/// connection (or the app being closed) loses nothing: everything is retried,
/// in order, until it lands. The server applies each entry idempotently, so a
/// retry can never double-count or overwrite a newer edit.
class LiveLogOutbox {
  LiveLogOutbox._();
  static const _key = "live_log_outbox_v1";

  static List<Map<String, dynamic>>? _ops;
  static bool _flushing = false;
  static Timer? _retry;
  static final ValueNotifier<int> pending = ValueNotifier<int>(0);

  static Future<List<Map<String, dynamic>>> _load() async {
    final cached = _ops;
    if (cached != null) return cached;
    var list = <Map<String, dynamic>>[];
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        list = (jsonDecode(raw) as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
      }
    } catch (_) {}
    _ops = list;
    pending.value = list.length;
    return list;
  }

  static Future<void> _save() async {
    final ops = _ops ?? const [];
    pending.value = ops.length;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(ops));
    } catch (_) {}
  }

  /// Opens the queue from disk (so entries left from a previous run are retried).
  static Future<void> init() async {
    await _load();
    if (_ops!.isNotEmpty) unawaited(flush());
  }

  static Future<void> add(Map<String, dynamic> op) async {
    final ops = await _load();
    _ops = queueLiveLogOp(ops, op);
    await _save();
    unawaited(flush());
  }

  static bool _transient(Object e) {
    if (e is PostgrestException) {
      // Only a rejected token is worth retrying; the rest (permissions, bad
      // data) would fail forever and block everything behind them.
      return e.code == "PGRST301" || (e.message.toLowerCase().contains("jwt"));
    }
    return true; // no network, timeout, etc.
  }

  static Future<void> flush() async {
    if (_flushing) return;
    final me = SupabaseService.currentUser?.id;
    if (me == null) return;
    _flushing = true;
    _retry?.cancel();
    var failed = false;
    try {
      final ops = await _load();
      var i = 0;
      while (i < ops.length) {
        final op = ops[i];
        if (op["by"] != me) {
          i++; // another account's entry — leave it for them
          continue;
        }
        try {
          await _send(op);
          ops.removeAt(i);
          await _save();
        } catch (e) {
          if (_transient(e)) {
            failed = true;
            break;
          }
          if (kDebugMode) debugPrint("[live log] dropped entry: $e");
          ops.removeAt(i);
          await _save();
        }
      }
    } finally {
      _flushing = false;
    }
    if (failed) _retry = Timer(const Duration(seconds: 6), () => unawaited(flush()));
  }

  static Future<void> _send(Map<String, dynamic> op) async {
    final c = SupabaseService.client;
    if (op["t"] == "set") {
      await c.rpc("upsert_live_set", params: {
        "p_client": op["client"],
        "p_date": op["date"],
        "p_day": op["day"],
        "p_program": op["program"],
        "p_exercise": op["exercise"],
        "p_set": op["set"],
        "p_field": op["field"],
        "p_value": op["value"],
        "p_at": op["at"],
      }).timeout(const Duration(seconds: 15));
    } else if (op["t"] == "note") {
      await c
          .from("live_log_notes")
          .upsert(
            {
              "id": op["id"],
              "client_id": op["client"],
              "log_date": op["date"],
              "day_id": op["day"],
              "exercise_name": op["exercise"],
              "author_id": op["by"],
              "author_role": op["role"],
              "author_name": op["name"],
              "body": op["body"],
              "created_at": op["at"],
            },
            onConflict: "id",
            ignoreDuplicates: true,
          )
          .timeout(const Duration(seconds: 15));
    }
  }
}

/// The shared live log for one client's one program day on one date.
/// Everyone who opens the same client / date / day sees and edits the same
/// rows: the controller loads them, listens for changes, and sends this
/// device's edits through [LiveLogOutbox].
class LiveLogController {
  LiveLogController({
    required this.clientId,
    required this.date,
    required this.dayId,
    required this.programId,
    required this.myName,
    required this.myRole,
  });

  final String clientId;
  final String date; // yyyy-MM-dd
  final String dayId;
  final String programId;
  final String myName;
  final String myRole; // client | coach | owner

  final Map<String, LiveSetValue> sets = {};
  final List<LiveNote> notes = [];

  /// Bumps whenever someone ELSE's change (or the first load) changes the data.
  final ValueNotifier<int> remoteTick = ValueNotifier<int>(0);

  /// Bumps when notes change (including your own).
  final ValueNotifier<int> notesTick = ValueNotifier<int>(0);

  RealtimeChannel? _channel;
  Timer? _poll;
  bool _disposed = false;

  String get _me => SupabaseService.currentUser?.id ?? "";

  static String key(String exercise, int setNum) => "${exercise}__$setNum";

  Future<void> start() async {
    await LiveLogOutbox.init();
    await _reload();
    final name = "live_log_${clientId}_${date}_${dayId.hashCode}_${DateTime.now().microsecondsSinceEpoch}";
    _channel = SupabaseService.client.channel(name);
    for (final table in const ["live_set_logs", "live_log_notes"]) {
      _channel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: table,
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: "client_id", value: clientId),
        callback: (payload) {
          final rec = payload.newRecord;
          if (rec.isNotEmpty && (rec["log_date"]?.toString() != date || rec["day_id"]?.toString() != dayId)) return;
          if (table == "live_set_logs") {
            if (rec.isNotEmpty) _applyRow(rec);
            _bumpRemote();
          } else {
            if (rec.isNotEmpty) _applyNote(rec);
            notesTick.value++;
          }
        },
      );
    }
    _channel!.subscribe((status, error) {
      // On (re)connect, catch up on anything missed and push anything queued.
      if (status == RealtimeSubscribeStatus.subscribed && !_disposed) {
        unawaited(_reload());
        unawaited(LiveLogOutbox.flush());
      }
    });
    // Safety net behind the realtime socket (e.g. a mobile network handover).
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(_reload()));
  }

  Future<void> _reload() async {
    try {
      final c = SupabaseService.client;
      final rows = await c.from("live_set_logs").select().eq("client_id", clientId).eq("log_date", date).eq("day_id", dayId);
      final noteRows = await c.from("live_log_notes").select().eq("client_id", clientId).eq("log_date", date).eq("day_id", dayId).order("created_at");
      if (_disposed) return;
      for (final r in rows) {
        _applyRow(r);
      }
      for (final r in noteRows) {
        _applyNote(r);
      }
      _bumpRemote();
      notesTick.value++;
    } catch (_) {
      // Offline: keep showing what we have; the poll / reconnect will retry.
    }
  }

  void _bumpRemote() {
    if (!_disposed) remoteTick.value++;
  }

  DateTime? _ts(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toUtc();

  void _applyRow(Map<String, dynamic> r) {
    final k = key(r["exercise_name"].toString(), (r["set_num"] as num).toInt());
    final cur = sets.putIfAbsent(k, () => LiveSetValue());
    final rAt = _ts(r["reps_at"]);
    if (rAt != null && (cur.repsAt == null || rAt.isAfter(cur.repsAt!))) {
      cur.reps = (r["reps"] as num?)?.toInt();
      cur.repsAt = rAt;
    }
    final wAt = _ts(r["weight_at"]);
    if (wAt != null && (cur.weightAt == null || wAt.isAfter(cur.weightAt!))) {
      cur.weight = (r["weight"] as num?)?.toDouble();
      cur.weightAt = wAt;
    }
  }

  void _applyNote(Map<String, dynamic> r) {
    final id = r["id"].toString();
    if (notes.any((n) => n.id == id)) return;
    notes.add(LiveNote(
      id: id,
      exercise: r["exercise_name"].toString(),
      authorId: r["author_id"].toString(),
      authorName: (r["author_name"] ?? "").toString(),
      authorRole: (r["author_role"] ?? "").toString(),
      body: r["body"].toString(),
      createdAt: _ts(r["created_at"]) ?? DateTime.now().toUtc(),
    ));
    notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// This device changed a field. Shown immediately, then synced (now, or as
  /// soon as the connection is back).
  void setField(String exercise, int setNum, String field, Object? value) {
    final now = DateTime.now().toUtc();
    final cur = sets.putIfAbsent(key(exercise, setNum), () => LiveSetValue());
    if (field == "reps") {
      cur.reps = (value as num?)?.toInt();
      cur.repsAt = now;
    } else {
      cur.weight = (value as num?)?.toDouble();
      cur.weightAt = now;
    }
    unawaited(LiveLogOutbox.add({
      "t": "set",
      "by": _me,
      "client": clientId,
      "date": date,
      "day": dayId,
      "program": programId,
      "exercise": exercise,
      "set": setNum,
      "field": field,
      "value": value,
      "at": now.toIso8601String(),
    }));
  }

  void addNote(String exercise, String body) {
    final text = body.trim();
    if (text.isEmpty) return;
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc();
    notes.add(LiveNote(
      id: id,
      exercise: exercise,
      authorId: _me,
      authorName: myName,
      authorRole: myRole,
      body: text,
      createdAt: now,
    ));
    notesTick.value++;
    unawaited(LiveLogOutbox.add({
      "t": "note",
      "id": id,
      "by": _me,
      "client": clientId,
      "date": date,
      "day": dayId,
      "exercise": exercise,
      "role": myRole,
      "name": myName,
      "body": text,
      "at": now.toIso8601String(),
    }));
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    final c = _channel;
    if (c != null) SupabaseService.client.removeChannel(c);
    remoteTick.dispose();
    notesTick.dispose();
  }
}

/// Which of a client's days have live activity today — used to show "Live
/// now" on the day list and to let a coach open a client who is working out
/// on their own.
class LiveActivity {
  LiveActivity._();

  /// Bumped when this phone starts or ends a live day, so the open screen
  /// re-reads without waiting on the realtime socket.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void changed() => revision.value++;

  /// Rows touched in the last [within], newest first. [clientId] null = every
  /// client the signed-in staff member can read.
  static Future<List<Map<String, dynamic>>> recent({String? clientId, Duration within = const Duration(hours: 3)}) async {
    final since = DateTime.now().toUtc().subtract(within).toIso8601String();
    var q = SupabaseService.client.from("live_set_logs").select("client_id, log_date, day_id, updated_at, ended_at").gte("updated_at", since);
    if (clientId != null) q = q.eq("client_id", clientId);
    final rows = await q.order("updated_at", ascending: false).limit(200);
    // A workout that was saved or whose session was ended is over; it only
    // counts as live again if someone logs something after that.
    return rows.map((r) => r.cast<String, dynamic>()).where((r) {
      final ended = DateTime.tryParse(r["ended_at"]?.toString() ?? "");
      if (ended == null) return true;
      final updated = DateTime.tryParse(r["updated_at"]?.toString() ?? "");
      return updated != null && updated.isAfter(ended);
    }).toList();
  }

  /// The single open live day for one client, or null. Unfinished set logs
  /// are not consulted.
  static Future<String?> currentDay(String clientId) async {
    final map = await openDays(clientId: clientId);
    return map[clientId];
  }

  /// Open live-day rows, each with its newest set change in the last
  /// [liveDayIdleLimit], so callers can drop days nobody has touched.
  static Future<List<LiveDayRun>> openRuns({String? clientId}) async {
    var q = SupabaseService.client
        .from("live_day_runs")
        .select("client_id, log_date, day_id, started_role, started_at, ended_at")
        .isFilter("ended_at", null);
    if (clientId != null) q = q.eq("client_id", clientId);
    final rows = await q;
    if ((rows as List).isEmpty) return const [];

    // Newest set change per client / date / day, only as far back as the
    // idle limit: anything older can't keep a day live anyway.
    final latest = <String, DateTime>{};
    try {
      final since = DateTime.now().toUtc().subtract(liveDayIdleLimit).toIso8601String();
      var sq = SupabaseService.client
          .from("live_set_logs")
          .select("client_id, log_date, day_id, updated_at")
          .gte("updated_at", since);
      if (clientId != null) sq = sq.eq("client_id", clientId);
      final sets = await sq.order("updated_at", ascending: false).limit(500);
      for (final raw in sets as List) {
        final r = (raw as Map).cast<String, dynamic>();
        final at = DateTime.tryParse(r["updated_at"]?.toString() ?? "");
        if (at == null) continue;
        final k = "${r["client_id"]}|${r["log_date"]}|${r["day_id"]}";
        final have = latest[k];
        if (have == null || at.isAfter(have)) latest[k] = at;
      }
    } catch (_) {
      // Without set activity the start time alone decides.
    }

    final runs = <LiveDayRun>[];
    for (final raw in rows) {
      final row = (raw as Map).cast<String, dynamic>();
      final started = DateTime.tryParse(row["started_at"]?.toString() ?? "");
      final dayId = row["day_id"]?.toString() ?? "";
      final who = row["client_id"]?.toString() ?? "";
      if (started == null || dayId.isEmpty || who.isEmpty) continue;
      runs.add(LiveDayRun(
        clientId: who,
        dayId: dayId,
        startedAt: started,
        lastActivityAt: latest["$who|${row["log_date"]}|$dayId"],
        startedRole: row["started_role"]?.toString(),
      ));
    }
    return runs;
  }

  /// client id -> the one day that is live right now. A day with no set
  /// activity for [liveDayIdleLimit] is not live, even if its row is open.
  static Future<Map<String, String>> openDays({String? clientId}) async {
    final runs = await openRuns(clientId: clientId);
    return currentLiveDayByClient(runs, now: DateTime.now());
  }

  /// Closes every open live day except [keepDayId] on [keepDate]. The same
  /// day left open on an earlier date is closed too, so a client never has
  /// two open rows for one program day. Set logs stay writable. Matching
  /// start-of-day markers in live_set_logs are closed too; real set rows
  /// are not touched.
  static Future<void> closeOtherDays(String clientId, {required String keepDayId, String? keepDate}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      var q = SupabaseService.client
          .from("live_day_runs")
          .update({"ended_at": now})
          .eq("client_id", clientId)
          .isFilter("ended_at", null);
      q = keepDate == null
          ? q.neq("day_id", keepDayId)
          : q.or("day_id.neq.\"$keepDayId\",log_date.neq.$keepDate");
      await q;
    } catch (_) {}
    await closeOpenStartMarkers(clientId, now: now, keepDayId: keepDayId, keepDate: keepDate);
  }

  /// End / timeout. Closes the live marker only, not the workout log, and
  /// also closes leftover start-of-day marker rows so the client bar clears.
  static Future<void> closeAllDays(String clientId) async {
    var ended = false;
    try {
      await SupabaseService.client.rpc("end_open_live_days", params: {"p_client": clientId});
      ended = true;
    } catch (_) {}
    final now = DateTime.now().toUtc().toIso8601String();
    if (!ended) {
      try {
        await SupabaseService.client
            .from("live_day_runs")
            .update({"ended_at": now})
            .eq("client_id", clientId)
            .isFilter("ended_at", null);
      } catch (_) {}
    }
    // The live function may not close markers until the new migration is
    // applied, so the app always closes them here as well.
    await closeOpenStartMarkers(clientId, now: now);
  }

  /// Closes open `__day_started_coach__` / `__day_started_client__` rows.
  /// Real set logs and saved workouts are never updated.
  static Future<void> closeOpenStartMarkers(
    String clientId, {
    required String now,
    String? keepDayId,
    String? keepDate,
  }) async {
    try {
      var q = SupabaseService.client
          .from("live_set_logs")
          .update({"ended_at": now})
          .eq("client_id", clientId)
          .isFilter("ended_at", null)
          .inFilter("exercise_name", liveDayStartMarkers);
      if (keepDayId != null) {
        q = keepDate == null
            ? q.neq("day_id", keepDayId)
            : q.or("day_id.neq.\"$keepDayId\",log_date.neq.$keepDate");
      }
      await q;
    } catch (_) {}
  }

  /// Finishes one program day. A different day logged on the same date stays open.
  static Future<void> end(String clientId, String isoDate, {required String dayId}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await SupabaseService.client.rpc("end_live_logs", params: {
        "p_client": clientId,
        "p_date": isoDate,
        "p_day": dayId,
      });
    } catch (_) {
      try {
        await SupabaseService.client
            .from("live_set_logs")
            .update({"ended_at": now})
            .eq("client_id", clientId)
            .eq("log_date", isoDate)
            .eq("day_id", dayId);
      } catch (_) {}
    }
    try {
      await SupabaseService.client
          .from("live_day_runs")
          .update({"ended_at": now})
          .eq("client_id", clientId)
          .eq("log_date", isoDate)
          .eq("day_id", dayId);
    } catch (_) {}
  }

  static RealtimeChannel watch({String? clientId, required void Function() onChange}) {
    final ch = SupabaseService.client.channel("live_activity_${clientId ?? "all"}_${DateTime.now().microsecondsSinceEpoch}");
    ch.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: "public",
      table: "live_set_logs",
      filter: clientId == null ? null : PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: "client_id", value: clientId),
      callback: (_) => onChange(),
    );
    ch.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: "public",
      table: "live_day_runs",
      filter: clientId == null ? null : PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: "client_id", value: clientId),
      callback: (_) => onChange(),
    );
    ch.subscribe();
    return ch;
  }
}
