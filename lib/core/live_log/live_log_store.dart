import "dart:async";
import "dart:convert";

import "package:shared_preferences/shared_preferences.dart";

/// One typed value, kept as the exact text that was entered.
///
/// "20" stays "20". A later reload must not replace it with an earlier
/// keystroke such as "2".
class LiveLogCell {
  const LiveLogCell({required this.raw, required this.at});
  final String raw;
  final DateTime at;

  Map<String, dynamic> toJson(String key) => {
        "k": key,
        "raw": raw,
        "at": at.toUtc().toIso8601String(),
      };

  static LiveLogCell? fromJson(Map<String, dynamic> j) {
    final at = DateTime.tryParse(j["at"]?.toString() ?? "");
    if (at == null) return null;
    return LiveLogCell(raw: j["raw"]?.toString() ?? "", at: at.toUtc());
  }
}

/// Every logged rep and weight, keyed by session + client + exercise + set.
///
/// Nothing is shared between clients, and a set is never identified by its
/// position alone. Each change is written here immediately, then this store
/// is what the screen reads when the coach comes back.
class LiveLogStore {
  LiveLogStore({this.persist, this.loadRaw});

  /// The store the running app uses. Tests build their own.
  static final instance = LiveLogStore(
    persist: _persistPrefs,
    loadRaw: _loadPrefs,
  );

  static const prefsKey = "live_log_store_v1";

  final Future<void> Function(String encoded)? persist;
  final Future<String?> Function()? loadRaw;

  final Map<String, LiveLogCell> _cells = {};
  String? openClientId;
  int? openSlot;
  final Map<String, int> exerciseIndexByClient = {};
  bool _loaded = false;
  Future<void>? _loading;

  static String key({
    required String sessionId,
    required String clientId,
    required String exerciseId,
    required int setIndex,
    required String field,
  }) =>
      [sessionId, clientId, exerciseId, "$setIndex", field].join("\u001f");

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= () async {
      try {
        final raw = await loadRaw?.call();
        if (raw != null && raw.isNotEmpty) _read(raw);
      } catch (_) {}
      _loaded = true;
    }();
  }

  /// Saves [raw] when [at] is newer than what is already stored.
  /// Returns the text that should be shown.
  String remember({
    required String sessionId,
    required String clientId,
    required String exerciseId,
    required int setIndex,
    required String field,
    required String raw,
    required DateTime at,
  }) {
    final k = key(
      sessionId: sessionId,
      clientId: clientId,
      exerciseId: exerciseId,
      setIndex: setIndex,
      field: field,
    );
    final cur = _cells[k];
    final stamp = at.toUtc();
    if (cur != null && !stamp.isAfter(cur.at)) return cur.raw;
    _cells[k] = LiveLogCell(raw: raw, at: stamp);
    unawaited(_write());
    return raw;
  }

  String? raw({
    required String sessionId,
    required String clientId,
    required String exerciseId,
    required int setIndex,
    required String field,
  }) =>
      _cells[key(
        sessionId: sessionId,
        clientId: clientId,
        exerciseId: exerciseId,
        setIndex: setIndex,
        field: field,
      )]
          ?.raw;

  void rememberPlace({
    String? clientId,
    int? slot,
    String? exerciseClientId,
    int? exerciseIndex,
    bool clear = false,
  }) {
    if (clear) {
      openClientId = null;
      openSlot = null;
    } else {
      if (clientId != null) openClientId = clientId;
      if (slot != null) openSlot = slot;
      if (exerciseClientId != null && exerciseIndex != null) {
        exerciseIndexByClient[exerciseClientId] = exerciseIndex;
      }
    }
    unawaited(_write());
  }

  Future<void> flush() => _write();

  Future<void> _write() async {
    final saver = persist;
    if (saver == null) return;
    try {
      await saver(jsonEncode({
        "cells": [for (final e in _cells.entries) e.value.toJson(e.key)],
        "ui": {
          "clientId": openClientId,
          "slot": openSlot,
          "exercise": exerciseIndexByClient,
        },
      }));
    } catch (_) {}
  }

  void _read(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) return;
    final cells = decoded["cells"];
    if (cells is List) {
      for (final item in cells) {
        if (item is! Map) continue;
        final cell = LiveLogCell.fromJson(item.cast<String, dynamic>());
        final k = item["k"]?.toString();
        if (cell == null || k == null || k.isEmpty) continue;
        final cur = _cells[k];
        if (cur == null || cell.at.isAfter(cur.at)) _cells[k] = cell;
      }
    }
    final ui = decoded["ui"];
    if (ui is Map) {
      openClientId = ui["clientId"]?.toString();
      openSlot = ui["slot"] is num ? (ui["slot"] as num).toInt() : null;
      final exercise = ui["exercise"];
      if (exercise is Map) {
        exercise.forEach((k, v) {
          if (v is num) exerciseIndexByClient[k.toString()] = v.toInt();
        });
      }
    }
  }

  static Future<void> _persistPrefs(String encoded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, encoded);
  }

  static Future<String?> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefsKey);
  }
}

/// The full number that was typed. 20 stays 20. A blank field stays blank.
String liveLogNumberText(String raw) => raw;

/// Parses a finished entry for colours and history. Partial text such as
/// "2" while "20" is still being typed is not written back over the field.
double? liveLogWeight(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty || t == "." || t == "-") return null;
  return double.tryParse(t);
}

int? liveLogReps(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty || t == "-") return null;
  return int.tryParse(t);
}
