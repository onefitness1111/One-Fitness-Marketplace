import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/widgets/swipeable_tab_view.dart";
import "../../client/log_progress/exercise_lifts_tab.dart";
import "../../../data/providers/trainer_providers.dart";
import "coach_health_section.dart";
import "coach_measurements_tab.dart";
import "photos_tab.dart";

/// Same tab row as the client's Log Progress. Overview is shared health
/// data. Body and Photos are the measurement log and the photo cards.
/// Lifts is read only.
class ProgressTab extends StatelessWidget {
  const ProgressTab({super.key, required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context) {
    return SwipeableTabView(
      labels: const ["Overview", "Body", "Lifts", "Photos"],
      children: [
        CoachHealthSection(clientId: clientId),
        CoachMeasurementsTab(clientId: clientId),
        _CoachLifts(clientId: clientId),
        PhotosTab(clientId: clientId),
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
