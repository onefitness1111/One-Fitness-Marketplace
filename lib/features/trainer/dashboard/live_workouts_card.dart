import "dart:async";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "../../../core/live_log/live_log_sync.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/workout_log.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "../../shared/session_logger_view.dart";

/// "Working out now": clients who are logging a workout today (on their own or
/// with you), so a coach can open it and watch, log or correct sets live.
class LiveWorkoutsCard extends ConsumerStatefulWidget {
  const LiveWorkoutsCard({super.key});

  @override
  ConsumerState<LiveWorkoutsCard> createState() => _LiveWorkoutsCardState();
}

class _LiveWorkoutsCardState extends ConsumerState<LiveWorkoutsCard> {
  /// client id -> the program day they are logging.
  Map<String, String> _active = {};
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _refresh();
    try {
      _channel = LiveActivity.watch(onChange: _refresh);
    } catch (_) {}
  }

  @override
  void dispose() {
    final c = _channel;
    if (c != null) SupabaseService.client.removeChannel(c);
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final rows = await LiveActivity.recent(within: const Duration(hours: 2));
      final today = isoToday();
      final map = <String, String>{};
      for (final r in rows) {
        if (r["log_date"]?.toString() != today) continue;
        map.putIfAbsent(r["client_id"].toString(), () => r["day_id"].toString());
      }
      if (mounted) setState(() => _active = map);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final trainerAuth = ref.watch(trainerAuthProvider);
    final isOwner = trainerAuth == "owner";
    final roster = ref.watch(trainerRosterProvider);
    final mine = roster.where((c) => _active.containsKey(c.id) && (isOwner || c.primaryTrainerId == trainerAuth)).toList();
    if (mine.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("Working out now"),
          for (final c in mine)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LiveWorkoutPage(clientId: c.id, clientName: c.name, dayId: _active[c.id]!),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.radio, size: 18, color: AppColors.grn),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text("${c.name} is logging a workout", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    Text("Watch live", style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class LiveWorkoutPage extends ConsumerWidget {
  const LiveWorkoutPage({super.key, required this.clientId, required this.clientName, this.dayId});

  final String clientId;
  final String clientName;
  final String? dayId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(trainerClientRecordsProvider)[clientId];
    final isOwner = ref.watch(trainerAuthProvider) == "owner";
    final trainerAuth = ref.watch(trainerAuthProvider);
    final me = ref.watch(trainersProvider).where((t) => t.id == trainerAuth);
    final myName = isOwner ? "Owner" : (me.isNotEmpty ? me.first.displayTitle : "Coach");

    Future<void> save(WorkoutLogEntry entry) async {
      final rec = ref.read(trainerClientRecordsProvider)[clientId];
      final logs = [...?rec?.workoutLogs.where((l) => l.id != entry.id), entry];
      await SupabaseService.appendWorkoutLog(clientId, entry);
      ref.read(trainerClientRecordsProvider.notifier).update(clientId, (r) => r.copyWith(workoutLogs: logs));
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(clientName), backgroundColor: AppColors.bg),
      body: record == null
          ? const Padding(padding: EdgeInsets.all(18), child: HintBox(text: "This client's record hasn't loaded yet."))
          : SessionLoggerView(
              key: ValueKey(clientId),
              client: record,
              loggedBy: "coach",
              loggedByName: myName,
              sessionId: "live|$clientId",
              authorName: myName,
              authorRole: isOwner ? "owner" : "coach",
              initialDayId: dayId,
              emptyProgramText: "This client doesn't have an active workout program yet.",
              onSave: save,
            ),
    );
  }
}
