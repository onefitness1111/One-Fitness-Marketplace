import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "coach_measurements_tab.dart";
import "merit_badges_tab.dart";
import "photos_tab.dart";

/// Photos, measurements, and badges on one page. Each section is the same
/// tab it used to be, stacked so nothing is dropped.
class ProgressTab extends StatelessWidget {
  const ProgressTab({super.key, required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
      children: [
        PhotosTab(clientId: clientId, embedded: true),
        const _SectionRule(),
        CoachMeasurementsTab(clientId: clientId, embedded: true),
        const _SectionRule(),
        MeritBadgesTab(clientId: clientId, embedded: true),
      ],
    );
  }
}

class _SectionRule extends StatelessWidget {
  const _SectionRule();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1, thickness: 1, color: AppColors.line),
    );
  }
}
