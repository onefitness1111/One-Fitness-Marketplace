import "package:flutter/material.dart";
import "../theme/app_colors.dart";
import "../utils/schedule_day_fill.dart";

/// Black, gray, and white only.
/// Open is a gray ring, booked is a gray dot, full is a white dot.
class ScheduleDayDot extends StatelessWidget {
  const ScheduleDayDot({super.key, required this.fill, this.onDark = false});

  final ScheduleDayFill? fill;

  /// Selected booking days paint the number black, so the dot has to stay
  /// visible on that light chip.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final fill = this.fill;
    if (fill == null) return const SizedBox(width: 6, height: 6);
    final ring = onDark ? Colors.black : AppColors.txt;
    final gray = onDark ? Colors.black : AppColors.mute;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: switch (fill) {
          ScheduleDayFill.open => Colors.transparent,
          ScheduleDayFill.booked => gray,
          ScheduleDayFill.full => ring,
        },
        border: Border.all(
          color: fill == ScheduleDayFill.open ? gray : Colors.transparent,
          width: 1.2,
        ),
      ),
    );
  }
}

class ScheduleDayLegend extends StatelessWidget {
  const ScheduleDayLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          _Item(fill: ScheduleDayFill.open, label: "Open"),
          SizedBox(width: 14),
          _Item(fill: ScheduleDayFill.booked, label: "Booked"),
          SizedBox(width: 14),
          _Item(fill: ScheduleDayFill.full, label: "Full"),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.fill, required this.label});
  final ScheduleDayFill fill;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScheduleDayDot(fill: fill),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: AppColors.mute)),
      ],
    );
  }
}
