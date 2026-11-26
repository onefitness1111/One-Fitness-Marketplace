import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../data/models/availability_block.dart";
import "../../../data/models/trainer.dart";

/// Pieces of a coach's card on the one Staff page (U7). They used to live
/// on the old Staff tab's roster cards; the merged page shows them when a
/// coach's card is opened.

String staffPayoutSummary(Trainer t) {
  final rate = "\$${(t.payoutRateCents / 100).toStringAsFixed(2)}";
  final unit = switch (t.payoutMode) {
    "perClient" => "client",
    "perHour" => "hour",
    _ => "session",
  };
  return "$rate/$unit";
}

const _staffWeekdayLabels = {1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu", 5: "Fri", 6: "Sat"};

/// Mirrors FormPrimitives.jsx `AvailSummary` — a compact weekly Mon-Sat
/// slot grid per availability block (session type/discipline label, then
/// one line per working day of that block's open slots).
class StaffAvailSummary extends StatelessWidget {
  const StaffAvailSummary({super.key, required this.availability});
  final List<AvailabilityBlock> availability;

  @override
  Widget build(BuildContext context) {
    if (availability.isEmpty) {
      return const StaffIconLine(icon: LucideIcons.clock, text: "No availability set");
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: availability.map((b) {
        final working = _staffWeekdayLabels.entries.where((e) => (b.byDay[e.key] ?? const []).isNotEmpty).toList();
        if (working.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(LucideIcons.clock, size: 12, color: AppColors.gold),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${sessionTypeLabel(b.sessionType)} · ${disciplineLabel(b.discipline)}",
                      style: TextStyle(fontSize: 11, color: AppColors.gold, fontWeight: FontWeight.w700),
                    ),
                    ...working.map((e) {
                      final slots = [...b.byDay[e.key]!]..sort();
                      return Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: RichText(
                          text: TextSpan(
                            style: TextStyle(fontSize: 12, color: AppColors.mute),
                            children: [
                              TextSpan(
                                text: "${e.value}  ",
                                style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700),
                              ),
                              TextSpan(text: slots.map(fmtSlotShort).join(" ")),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class StaffIconLine extends StatelessWidget {
  const StaffIconLine({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: AppColors.mute),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(fontSize: 11, color: AppColors.mute),
          ),
        ],
      ),
    );
  }
}
