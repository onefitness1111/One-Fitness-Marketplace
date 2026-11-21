import "package:supabase_flutter/supabase_flutter.dart";

import "../supabase/supabase_service.dart";
import "health_stats.dart";

/// A client's shared reading, already checked for consent.
class HealthCoachPayload {
  const HealthCoachPayload({required this.reading, required this.shareWithCoach});

  final HealthReading reading;
  final bool shareWithCoach;
}

/// Writes the client's own rows and reads them back for a coach.
///
/// Every call is allowed to fail. The tables are added in a migration the
/// owner applies separately, and build 17 has to keep working before that.
class HealthSync {
  HealthSync({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _db => _client ?? SupabaseService.client;

  Future<HealthPersistOutcome> save({
    required String? accountId,
    required HealthReading reading,
    required bool shareWithCoach,
  }) async {
    if (accountId == null || accountId.isEmpty) {
      return persistOutcome(requestedShare: shareWithCoach, localOnly: true);
    }
    try {
      final db = _db;
      final now = DateTime.now().toUtc().toIso8601String();
      await db.from("health_connections").upsert({
        "client_id": accountId,
        "source": reading.sourceId,
        "share_with_coach": shareWithCoach,
        "last_synced_at": reading.syncedAt.toUtc().toIso8601String(),
        "updated_at": now,
      });
      final days = [for (final day in reading.days) day.toRow(accountId)];
      if (days.isNotEmpty) {
        await db.from("health_daily_stats").upsert(days, onConflict: "client_id,day");
      }
      final workouts = [for (final workout in reading.workouts) workout.toRow(accountId, reading.sourceId)];
      if (workouts.isNotEmpty) {
        await db.from("health_workouts").upsert(workouts, onConflict: "client_id,external_id");
      }
      return persistOutcome(requestedShare: shareWithCoach);
    } catch (error) {
      return persistOutcome(error: error, requestedShare: shareWithCoach);
    }
  }

  /// False when the row is missing, null when storage could not be read.
  Future<bool?> loadShare(String accountId) async {
    try {
      final row = await _db.from("health_connections").select("share_with_coach").eq("client_id", accountId).maybeSingle();
      if (row == null) return false;
      return row["share_with_coach"] == true;
    } catch (_) {
      return null;
    }
  }

  /// Null hides the coach section: no consent, no rows, or the tables are
  /// not there yet. A coach never sees a health error in place of photos.
  Future<HealthCoachPayload?> loadCoach(String clientId) async {
    try {
      final db = _db;
      final conn = await db
          .from("health_connections")
          .select("share_with_coach, source, last_synced_at")
          .eq("client_id", clientId)
          .maybeSingle();
      if (conn == null || conn["share_with_coach"] != true) return null;
      final since = isoDay(DateTime.now().subtract(const Duration(days: 90)));
      final dayRows = await db.from("health_daily_stats").select().eq("client_id", clientId).gte("day", since).order("day");
      final workoutRows = await db
          .from("health_workouts")
          .select()
          .eq("client_id", clientId)
          .order("started_at", ascending: false)
          .limit(30);
      final days = <HealthDay>[
        for (final row in dayRows as List)
          if (row is Map) ?HealthDay.fromRow(Map<String, dynamic>.from(row)),
      ];
      final workouts = <HealthWorkout>[
        for (final row in workoutRows as List)
          if (row is Map) ?HealthWorkout.fromRow(Map<String, dynamic>.from(row)),
      ];
      final synced = DateTime.tryParse("${conn["last_synced_at"]}")?.toLocal() ?? DateTime.now();
      final source = "${conn["source"]}";
      final reading = HealthReading(
        days: days,
        workouts: workouts,
        syncedAt: synced,
        sourceId: source,
        sourceLabel: source == "health_connect" ? "Health Connect" : "Apple Health",
      );
      if (!coachShouldShowHealth(shareWithCoach: true, storageUnavailable: false, hasAnyStat: reading.hasAny)) {
        return null;
      }
      return HealthCoachPayload(reading: reading, shareWithCoach: true);
    } catch (_) {
      return null;
    }
  }
}
