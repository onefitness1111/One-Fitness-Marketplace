import "package:flutter_riverpod/flutter_riverpod.dart";

import "../models/quiet_nudge.dart";

/// Home-screen pieces that used to load inside each card after the
/// dashboard was already on screen. They are filled before the shell
/// opens, so the first frame is the finished screen.
class DashboardExtras {
  const DashboardExtras({
    this.balanceCents,
    this.renewals = const [],
    this.liveDays = const {},
    this.nudges = const [],
  });

  /// Negative means the client owes the gym. Null or zero hides the banner.
  final int? balanceCents;
  final List<Map<String, dynamic>> renewals;
  final Map<String, String> liveDays;
  final List<QuietNudge> nudges;

  DashboardExtras copyWith({
    int? balanceCents,
    bool clearBalance = false,
    List<Map<String, dynamic>>? renewals,
    Map<String, String>? liveDays,
    List<QuietNudge>? nudges,
  }) =>
      DashboardExtras(
        balanceCents: clearBalance ? null : (balanceCents ?? this.balanceCents),
        renewals: renewals ?? this.renewals,
        liveDays: liveDays ?? this.liveDays,
        nudges: nudges ?? this.nudges,
      );
}

class DashboardExtrasNotifier extends Notifier<DashboardExtras> {
  @override
  DashboardExtras build() => const DashboardExtras();

  void replace(DashboardExtras next) => state = next;
}

final dashboardExtrasProvider =
    NotifierProvider<DashboardExtrasNotifier, DashboardExtras>(DashboardExtrasNotifier.new);
