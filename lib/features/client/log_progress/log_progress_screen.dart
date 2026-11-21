import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "exercise_lifts_tab.dart";
import "goal_progress_bar.dart";
import "health_section.dart";
import "measurements_tab.dart";
import "progress_photos_tab.dart";
import "results_card.dart";

const _ranges = [(30, "30d"), (90, "90d"), (365, "1yr"), (0, "All")];

/// One segment at a time. Overview is the health block. Body keeps the goal,
/// the share card, and the measurement log. Lifts and Photos are unchanged.
class LogProgressScreen extends StatefulWidget {
  const LogProgressScreen({super.key});

  @override
  State<LogProgressScreen> createState() => _LogProgressScreenState();
}

class _LogProgressScreenState extends State<LogProgressScreen> {
  int _segment = 0;
  int _range = 90;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
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
            0 => const HealthSection(),
            1 => Column(
                children: [
                  const GoalProgressBar(),
                  const ResultsShareButton(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                    child: Row(
                      children: [
                        for (final range in _ranges)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: TapHighlight(
                              onTap: () => setState(() => _range = range.$1),
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: _range == range.$1 ? AppColors.gold : Colors.transparent,
                                  border: Border.all(color: _range == range.$1 ? AppColors.gold : AppColors.line),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  range.$2,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: _range == range.$1 ? AppColors.onGold : AppColors.mute,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(child: MeasurementsTab(rangeDays: _range)),
                ],
              ),
            2 => const ExerciseLiftsTab(),
            _ => const ProgressPhotosTab(),
          },
        ),
      ],
    );
  }
}
