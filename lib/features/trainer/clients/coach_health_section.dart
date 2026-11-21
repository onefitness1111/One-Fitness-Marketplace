import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/health/health_stats.dart";
import "../../../core/health/health_sync.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/hint_box.dart";
import "../../../data/providers/trainer_providers.dart";
import "../../client/log_progress/health_panel.dart";

/// Coach Overview. Hidden behind the client's share switch, and absent when
/// the health tables are not there yet, so the rest of Progress still opens.
class CoachHealthSection extends ConsumerStatefulWidget {
  const CoachHealthSection({super.key, required this.clientId, this.load});

  final String clientId;
  final Future<HealthCoachPayload?> Function(String clientId)? load;

  @override
  ConsumerState<CoachHealthSection> createState() => _CoachHealthSectionState();
}

class _CoachHealthSectionState extends ConsumerState<CoachHealthSection> {
  HealthCoachPayload? _payload;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoachHealthSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clientId != widget.clientId) _load();
  }

  Future<void> _load() async {
    final loader = widget.load ?? HealthSync().loadCoach;
    final payload = await loader(widget.clientId);
    if (!mounted) return;
    setState(() {
      _payload = payload;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    final payload = _payload;
    final goal = ref.watch(trainerClientRecordsProvider)[widget.clientId]?.progressGoal;
    final weightGoal = goal != null && goal.kind == "weight" ? goal.target : null;
    final show = payload != null &&
        coachShouldShowHealth(
          shareWithCoach: payload.shareWithCoach,
          storageUnavailable: false,
          hasAnyStat: payload.reading.hasAny,
        );
    if (!show) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: const [
          HintBox(
            text: "No health stats shared yet. They show up here after your client connects a device and turns on sharing.",
          ),
        ],
      );
    }
    final reading = payload.reading;
    final now = DateTime.now();
    return ListView(
      key: const Key("coach-health-section"),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      children: [
        Text("Today · from connected devices", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.mute)),
        const SizedBox(height: 8),
        HealthFlagList(flags: healthFlags(days: reading.days, today: reading.syncedAt, weightGoalLb: weightGoal)),
        HealthTodayGrid(reading: reading, now: reading.syncedAt),
        HealthTrendsBlock(days: reading.days, now: reading.syncedAt, weightGoalLb: weightGoal),
        HealthWorkoutList(workouts: reading.workouts, now: now),
        Text(
          syncedLine(reading.syncedAt, now, reading.sourceLabel, reading.deviceNames),
          style: TextStyle(fontSize: 12, color: AppColors.mute),
        ),
      ],
    );
  }
}
