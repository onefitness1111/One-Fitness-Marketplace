import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/intake_resubmit.dart";
import "../../../core/utils/program_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/intake_forms.dart";
import "../../../data/providers/client_providers.dart";
import "../../shared/workout_history_list.dart";

/// Every saved workout, newest first. Older sessions stay on the list.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientRecordProvider);
    final cards = workoutHistory(client);
    final intake = intakeJourneyLines(
      client.intake,
      (key) => assessmentDefFor(key)?.title ?? "Intake",
    );

    if (cards.isEmpty && intake.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: HintBox(text: "Nothing logged yet. Log a session from your Dashboard."),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("Your history"),
          for (final line in intake)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(line.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                  Text(
                    line.at.isEmpty ? "" : line.at,
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                ],
              ),
            ),
          if (intake.isNotEmpty && cards.isNotEmpty) Divider(height: 28, color: AppColors.line),
          if (cards.isNotEmpty) WorkoutHistoryList(cards: cards),
        ],
      ),
    );
  }
}
