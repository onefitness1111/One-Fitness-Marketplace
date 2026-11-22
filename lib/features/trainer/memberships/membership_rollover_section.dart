import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";

/// How many unused sessions roll into the next month.
///
/// 0 means none. The number is the membership's own limit. A client can
/// still have a different limit on their profile, until Apply to everyone
/// clears those.
class MembershipRolloverFields extends StatelessWidget {
  const MembershipRolloverFields({
    super.key,
    required this.choice,
    required this.onChoice,
    required this.maxController,
  });

  /// 0 = nothing rolls over. 1 = roll up to the number in [maxController].
  final int choice;
  final ValueChanged<int> onChoice;
  final TextEditingController maxController;

  @override
  Widget build(BuildContext context) {
    final rolling = choice == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel("Rollover"),
        Text(
          "Unused sessions can roll into the next month. They last that month and do not stack.",
          style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4),
        ),
        const SizedBox(height: 10),
        SegmentedToggle(
          labels: const ["No rollover", "Roll over"],
          index: choice,
          onChanged: onChoice,
        ),
        const SizedBox(height: 10),
        if (rolling) ...[
          FieldLabeled(
            label: "Max unused rollover visits",
            child: AppField(
              controller: maxController,
              kind: FieldKind.integer,
              placeholder: "0",
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "How many unused sessions roll over. 0 means none.",
            style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
          ),
        ] else
          Text(
            "Unused sessions do not roll over. 0 means none.",
            style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
          ),
      ],
    );
  }
}

/// Last action on a membership: push its saved session count and rollover
/// limit onto every client currently on it.
class MembershipApplyButton extends StatelessWidget {
  const MembershipApplyButton({
    super.key,
    required this.applying,
    required this.onPressed,
  });

  final bool applying;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BtnGhost(
          full: true,
          onPressed: applying ? null : onPressed,
          child: Text(applying ? "Applying…" : "Apply to everyone on this membership"),
        ),
        const SizedBox(height: 6),
        Text(
          "Sets every client on this membership to its saved session count and rollover limit, and clears their personal overrides for this plan.",
          style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
        ),
      ],
    );
  }
}
