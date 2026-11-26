import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/report_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/report_range.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/supabase_bootstrap_provider.dart";
import "../../../data/providers/trainer_providers.dart";
import "../shell/trainer_shell_state.dart";
import "my_profile_screen.dart";
import "../reports/date_range_filter.dart";
import "../reports/payroll_reports.dart";

String _payoutModeLabel(String mode) => switch (mode) {
      "perClient" => "per client",
      "perHour" => "per hour",
      _ => "per session",
    };

/// Mirrors MyPay.jsx — a coach's own read-only pay screen, scoped to their
/// commission rate and their own sessions in the selected range.
class MyPayScreen extends ConsumerStatefulWidget {
  const MyPayScreen({super.key});

  @override
  ConsumerState<MyPayScreen> createState() => _MyPayScreenState();
}

class _MyPayScreenState extends ConsumerState<MyPayScreen> {
  ReportRange _range = presetRange("month");

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(trainerPayReadyProvider)) {
      return const Padding(padding: EdgeInsets.all(18), child: HintBox(text: "Loading pay…"));
    }
    final trainerAuth = ref.watch(trainerAuthProvider);
    final trainers = ref.watch(trainersProvider);
    final matches = trainers.where((t) => t.id == trainerAuth);
    if (matches.isEmpty) return const Padding(padding: EdgeInsets.all(18), child: HintBox(text: "No pay data available."));
    final me = matches.first;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("My Pay"),
          AppCard(
            borderColor: AppColors.goldDim,
            child: Text(
              "You're paid ${_payoutModeLabel(me.payoutMode)} at \$${(me.payoutRateCents / 100).toStringAsFixed(2)}"
              "${me.referralCommissionPercent > 0 ? ', plus ${me.referralCommissionPercent}% on purchases by clients who used your Coach Code' : ''}. "
              "Only clients who were checked in count — early cancels, late cancels, no-shows and unmarked bookings aren't paid.",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
          ),
          DateRangeFilter(range: _range, onChange: (r) => setState(() => _range = r)),
          const SizedBox(height: 12),
          const SectionLabel("Commissions"),
          ServiceCommissionsReport(range: _range, onlyTrainerId: me.id),
          const SizedBox(height: 12),
          const SectionLabel("Payroll Summary"),
          PayrollSummaryReport(range: _range, onlyTrainerId: me.id),
          const SizedBox(height: 12),
          const SectionLabel("Merit Badge Earnings"),
          MeritBadgeEarningsReport(range: _range, onlyTrainerId: me.id),
          const SizedBox(height: 12),
          // U8: this month's badge progress is shown on My Profile only.
          // Earnings above stay here because they are pay.
          TextButton(
            key: const Key("my-pay-badge-progress-link"),
            onPressed: () {
              ref.read(pendingMyProfileSectionProvider.notifier).set("badges");
              ref.read(trainerModeProvider.notifier).go("myprofile");
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.gold, padding: EdgeInsets.zero),
            child: const Text("See this month's badge progress on My Profile →", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
