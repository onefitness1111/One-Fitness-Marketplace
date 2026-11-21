import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/widgets/segmented_toggle.dart";
import "../../client/log_progress/exercise_lifts_tab.dart";
import "../../../data/providers/trainer_providers.dart";
import "coach_health_section.dart";
import "coach_measurements_tab.dart";
import "photos_tab.dart";

/// One segment at a time. Overview is shared health data. Body and Photos
/// are the measurement log and the photo cards. Lifts is read only.
class ProgressTab extends StatefulWidget {
  const ProgressTab({super.key, required this.clientId});

  final String clientId;

  @override
  State<ProgressTab> createState() => _ProgressTabState();
}

class _ProgressTabState extends State<ProgressTab> {
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: SegmentedToggle(
            labels: const ["Overview", "Body", "Lifts", "Photos"],
            index: _segment,
            onChanged: (index) => setState(() => _segment = index),
            itemKeys: const [
              Key("progress-segment-overview"),
              Key("progress-segment-body"),
              Key("progress-segment-lifts"),
              Key("progress-segment-photos"),
            ],
          ),
        ),
        Expanded(
          child: switch (_segment) {
            0 => CoachHealthSection(clientId: widget.clientId),
            1 => CoachMeasurementsTab(clientId: widget.clientId),
            2 => _CoachLifts(clientId: widget.clientId),
            _ => PhotosTab(clientId: widget.clientId),
          },
        ),
      ],
    );
  }
}

class _CoachLifts extends ConsumerWidget {
  const _CoachLifts({required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(trainerClientRecordsProvider)[clientId]?.workoutLogs ?? const [];
    return ExerciseLiftsTab(logs: logs, allowShare: false);
  }
}
