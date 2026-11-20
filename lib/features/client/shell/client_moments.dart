import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:supabase_flutter/supabase_flutter.dart";

import "../../../core/motion/pr_bus.dart";
import "../../../core/motion/pr_celebration.dart";
import "../../../core/motion/pr_logic.dart";
import "../../../core/motion/workout_complete_gate.dart";
import "../../../core/motion/workout_complete_screen.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/workout_logging.dart";
import "../../../data/models/workout_log.dart";
import "../../../data/providers/client_providers.dart";

/// Client-only overlays: a live PR, then a finished-workout summary the next
/// time the app is open. Neither waits on the other to load the shell.
class ClientMoments extends ConsumerStatefulWidget {
  const ClientMoments({super.key});

  @override
  ConsumerState<ClientMoments> createState() => _ClientMomentsState();
}

class _ClientMomentsState extends ConsumerState<ClientMoments> with WidgetsBindingObserver {
  RealtimeChannel? _live;
  String? _completeId;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PrBus.instance.flash.addListener(_onFlash);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _watchLive();
      unawaited(_checkComplete());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PrBus.instance.flash.removeListener(_onFlash);
    final channel = _live;
    if (channel != null) {
      try {
        SupabaseService.client.removeChannel(channel);
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkComplete());
  }

  void _onFlash() {
    if (mounted) setState(() {});
  }

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _watchLive() {
    final id = ref.read(clientInfoProvider).id;
    if (id.isEmpty) return;
    try {
      _live = SupabaseService.client
          .channel("client_pr_$id")
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: "public",
            table: "live_set_logs",
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: "client_id", value: id),
            callback: (payload) {
              final row = payload.newRecord;
              if (row.isEmpty) return;
              final weight = (row["weight"] as num?)?.toDouble();
              final name = row["exercise_name"]?.toString() ?? "";
              final setNum = (row["set_num"] as num?)?.toInt() ?? 0;
              if (name.startsWith("__")) return;
              _offer(name, setNum, weight);
            },
          )
          .subscribe();
    } catch (_) {}
  }

  void _offer(String name, int setNum, double? weight) {
    final logs = ref.read(clientRecordProvider).workoutLogs;
    PrBus.instance.consider(
      exercise: name,
      setNum: setNum,
      weight: weight,
      previousBest: bestLoggedWeightNamed(logs, name),
      appInForeground: _foreground,
    );
    if (weightIsPersonalRecord(previousBest: bestLoggedWeightNamed(logs, name), weight: weight)) {
      final id = ref.read(clientInfoProvider).id;
      if (id.isNotEmpty) unawaited(SupabaseService.awardMeritBadge(id, "record_breaker"));
    }
  }

  Future<void> _checkComplete() async {
    if (_checking || _completeId != null) return;
    final id = ref.read(clientInfoProvider).id;
    if (id.isEmpty) return;
    _checking = true;
    try {
      final stored = await SupabaseService.loadWorkoutCompleteSeen(id);
      final logs = ref.read(clientRecordProvider).workoutLogs;
      final decision = nextWorkoutComplete(
        logs: [
          for (final log in logs)
            LoggedWorkout(id: log.id, loggedAt: log.loggedAt ?? log.date, didWork: _didWork(log)),
        ],
        storedSeen: stored,
      );
      if (decision.seeded) {
        await SupabaseService.saveWorkoutCompleteSeen(id, decision.seen);
      }
      if (!mounted) return;
      if (decision.showId != null) setState(() => _completeId = decision.showId);
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  Future<void> _done() async {
    final id = ref.read(clientInfoProvider).id;
    final shown = _completeId;
    setState(() => _completeId = null);
    if (id.isEmpty || shown == null) return;
    try {
      final stored = await SupabaseService.loadWorkoutCompleteSeen(id) ?? const <String>[];
      await SupabaseService.saveWorkoutCompleteSeen(id, [...stored, shown]);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final flash = PrBus.instance.flash.value;
    final completeId = _completeId;
    if (flash != null) {
      return PrCelebration(flash: flash, onDone: PrBus.instance.dismiss);
    }
    if (completeId != null) {
      final log = ref.watch(clientRecordProvider).workoutLogs.where((l) => l.id == completeId);
      final entry = log.isEmpty ? null : log.first;
      final stats = entry == null
          ? const WorkoutCompleteStats(volume: 0, sets: 0, prs: 0, exercises: 0, streak: 0)
          : WorkoutCompleteStats(
              volume: sessionVolume(entry).round(),
              sets: entry.exercises.fold<int>(0, (n, e) => n + e.sets.where((s) => (s.completedReps ?? 0) > 0 || (s.completedWeight ?? 0) > 0).length),
              prs: sessionPrs(entry, ref.watch(clientRecordProvider).workoutLogs.where((l) => l.id != entry.id).toList()).length,
              exercises: entry.exercises.where((e) => e.sets.any((s) => (s.completedReps ?? 0) > 0 || (s.completedWeight ?? 0) > 0)).length,
              streak: workoutStreakDays(ref.watch(clientRecordProvider).workoutLogs, entry.date),
            );
      return WorkoutCompleteScreen(stats: stats, onDone: () => unawaited(_done()));
    }
    return const SizedBox.shrink();
  }
}

bool _didWork(WorkoutLogEntry log) {
  for (final exercise in log.exercises) {
    for (final set in exercise.sets) {
      if (set.completed || (set.completedReps ?? 0) > 0 || (set.completedWeight ?? 0) > 0) return true;
    }
  }
  return false;
}
