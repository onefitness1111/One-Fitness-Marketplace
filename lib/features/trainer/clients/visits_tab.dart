import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_utils.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";

/// Every visit a client has had or has coming, with its status: Upcoming,
/// Checked In, Early Cancel, Late Cancel, No Show (or Unmarked when a past
/// session was never marked). Booked sessions come from `bookings`; client
/// cancellations, which delete the booking, come from `cancelled_visits`.
class VisitsTab extends ConsumerStatefulWidget {
  const VisitsTab({super.key, required this.clientId});
  final String clientId;

  @override
  ConsumerState<VisitsTab> createState() => _VisitsTabState();
}

class _Visit {
  _Visit({required this.date, required this.slot, required this.type, required this.trainerId, required this.status});
  final String date;
  final int slot;
  final String type;
  final String trainerId;

  /// checked-in | early-cancel | late-cancel | no-show | upcoming | unmarked
  final String status;
}

class _VisitsTabState extends ConsumerState<VisitsTab> {
  String _tab = "upcoming";
  List<Map<String, dynamic>> _cancelled = [];
  bool _loaded = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.loadCancelledVisits(widget.clientId);
      if (mounted) setState(() { _cancelled = rows; _loaded = true; _failed = false; });
    } catch (_) {
      if (mounted) setState(() { _loaded = true; _failed = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookings = ref.watch(allBookingsProvider).where((b) => b.clientId == widget.clientId);
    final trainers = ref.watch(trainersProvider);
    final today = isoToday();

    final visits = <_Visit>[
      for (final b in bookings)
        _Visit(
          date: b.date,
          slot: b.slot,
          type: sessionTypeLabel(b.sessionType),
          trainerId: b.trainerId,
          status: b.attendanceStatus ?? (b.date.compareTo(today) >= 0 ? "upcoming" : "unmarked"),
        ),
      for (final c in _cancelled)
        _Visit(
          date: c["date"].toString(),
          slot: (c["slot_min"] as num?)?.toInt() ?? 0,
          type: sessionTypeLabel(c["session_type"]?.toString() ?? ""),
          trainerId: c["trainer_id"]?.toString() ?? "",
          status: c["status"].toString(),
        ),
    ];
    String key(_Visit v) => v.date + v.slot.toString().padLeft(4, "0");
    final upcoming = visits.where((v) => v.status == "upcoming" || (v.date.compareTo(today) >= 0 && v.status == "unmarked")).toList()
      ..sort((a, b) => key(a).compareTo(key(b)));
    final past = visits.where((v) => !upcoming.contains(v)).toList()..sort((a, b) => key(b).compareTo(key(a)));
    final shown = _tab == "upcoming" ? upcoming : past;

    int count(String s) => visits.where((v) => v.status == s).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final t in [("upcoming", "Upcoming (${upcoming.length})"), ("past", "Past (${past.length})")])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: t.$1 == "upcoming" ? 8 : 0),
                    child: TapHighlight(
                      onTap: () => setState(() => _tab = t.$1),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _tab == t.$1 ? AppColors.gold : AppColors.card,
                          border: Border.all(color: _tab == t.$1 ? AppColors.gold : AppColors.line),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          t.$2,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _tab == t.$1 ? AppColors.onGold : AppColors.mute,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_tab == "past") ...[
            const SizedBox(height: 10),
            Text(
              "Checked in ${count("checked-in")} · Early cancel ${count("early-cancel")} · Late cancel ${count("late-cancel")} · No show ${count("no-show")}",
              style: TextStyle(fontSize: 11.5, color: AppColors.mute),
            ),
          ],
          const SizedBox(height: 14),
          if (_failed) const HintBox(text: "Couldn't load cancelled visits — showing booked sessions only."),
          if (!_loaded)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text("Loading visits…", style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            )
          else if (shown.isEmpty)
            HintBox(text: _tab == "upcoming" ? "No upcoming visits." : "No past visits yet.")
          else
            for (final v in shown) _VisitRow(visit: v, coach: _coachName(trainers, v.trainerId)),
        ],
      ),
    );
  }

  String _coachName(List<dynamic> trainers, String id) {
    for (final t in trainers) {
      if (t.id == id) return t.displayTitle as String;
    }
    return "Coach";
  }
}

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.visit, required this.coach});
  final _Visit visit;
  final String coach;

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color color;
    switch (visit.status) {
      case "upcoming":
        label = "Upcoming";
        color = AppColors.gold;
      case "unmarked":
        label = "Unmarked";
        color = AppColors.mute;
      default:
        final m = kAttendanceOptions.where((o) => o.key == visit.status);
        label = m.isNotEmpty ? m.first.label : visit.status;
        color = m.isNotEmpty ? m.first.color : AppColors.mute;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("${dayLabel(visit.date)} · ${fmtSlot(visit.slot)}", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 3),
                  Text("$coach · ${visit.type}", style: TextStyle(fontSize: 12, color: AppColors.mute)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
              child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}
