import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/intake_resubmit.dart";
import "../../../core/utils/program_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/intake_forms.dart";
import "../../../data/providers/client_providers.dart";
import "../../../core/utils/date_utils.dart";
import "../../../data/models/trainer.dart";
import "../../shared/workout_history_list.dart";
import "past_session_card.dart";

/// Every saved workout, newest first. Older sessions stay on the list.
///
/// U6: this is also the one full past-sessions list — every booked session
/// before today with its attendance. Profile Settings > Visits and the
/// Dashboard's Workout Calendar link here instead of repeating it.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientRecordProvider);
    final cards = workoutHistory(client);
    final info = ref.watch(clientInfoProvider);
    final past = pastSessionsNewestFirst(
      ref.watch(clientBookingsProvider),
      clientId: info.id,
      today: isoToday(),
    );
    final trainers = ref.watch(trainersProvider);
    Trainer? trainerFor(String id) {
      for (final t in trainers) {
        if (t.id == id) return t;
      }
      return null;
    }
    final intake = intakeJourneyLines(
      client.intake,
      (key) => assessmentDefFor(key)?.title ?? "Intake",
    );

    if (cards.isEmpty && intake.isEmpty && past.isEmpty) {
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
          if (intake.isNotEmpty && (cards.isNotEmpty || past.isNotEmpty)) Divider(height: 28, color: AppColors.line),
          if (past.isNotEmpty) ...[
            const SectionLabel("Past sessions"),
            for (final b in past)
              PastSessionCard(
                key: Key("past-session-${b.id}"),
                booking: b,
                trainer: trainerFor(b.trainerId),
              ),
            if (cards.isNotEmpty) const SizedBox(height: 14),
          ],
          if (cards.isNotEmpty) ...[
            if (past.isNotEmpty) const SectionLabel("Logged workouts"),
            WorkoutHistoryList(cards: cards),
          ],
        ],
      ),
    );
  }
}
