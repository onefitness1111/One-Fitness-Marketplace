import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/late_fee_notice.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_utils.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/single_session_credit.dart";
import "../../../data/models/trainer.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/platform_settings_provider.dart";
import "../../../data/providers/trainer_providers.dart";
import "../booking/booking_cancel_screen.dart";

/// New "Visits" entry inside Profile Settings — upcoming sessions (with an
/// Edit menu offering Reschedule/Cancel). Past Visits links to History,
/// which holds the one full past-sessions list (U6). The cancel
/// flow mirrors day_detail_screen.dart's/booking_screen.dart's own
/// `_confirmCancel` exactly (same delete + late-cancel charge logic);
/// Reschedule reuses client_shell.dart's `startReschedule` so it lands on
/// the same booking picker every other Reschedule entry point uses.
class ClientVisitsSection extends ConsumerStatefulWidget {
  const ClientVisitsSection({
    super.key,
    required this.onBack,
    required this.onReschedule,
    this.onOpenHistory,
  });

  final VoidCallback onBack;
  final ValueChanged<Booking> onReschedule;

  /// Opens History, the one full past-sessions list (U6).
  final VoidCallback? onOpenHistory;

  @override
  ConsumerState<ClientVisitsSection> createState() =>
      _ClientVisitsSectionState();
}

class _ClientVisitsSectionState extends ConsumerState<ClientVisitsSection> {
  String _tab = "future"; // "future" | "past"
  Booking? _cancelTarget;
  bool _busy = false;
  String? _error;
  List<SingleSessionCredit> _credits = const [];

  @override
  void initState() {
    super.initState();
    _loadCredits();
  }

  Future<void> _loadCredits() async {
    final id = ref.read(clientInfoProvider).id;
    if (id.isEmpty) return;
    try {
      final c = await SupabaseService.loadSingleCredits(id);
      if (mounted) setState(() => _credits = c);
    } catch (_) {}
  }

  Future<void> _confirmCancel() async {
    if (_busy) return;
    final b = _cancelTarget!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Fee first: it is worked out from the booking, which is deleted next.
      // Always asked: the server decides early vs late and sends the right email.
      final feeRes = await takeLateCancelFee(b.id);
      await SupabaseService.deleteBooking(b.id, archive: true);
      ref.read(clientBookingsProvider.notifier).cancelBooking(b.id);
      // Also the gym-wide list the booking slots read, so the cancelled
      // session stops showing as booked.
      ref.read(allBookingsProvider.notifier).cancelBooking(b.id);
      // A client cancelling their own booking can only ever be "free" or
      // "late" — a no-show is by definition something the client never
      // reported, so self-cancel never produces one (see cancelWindow).
      final notice = lateFeeNotice(feeRes);
      if (notice != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice), duration: const Duration(seconds: 8)));
      }
      setState(() {
        _busy = false;
        _cancelTarget = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't cancel that session — check your connection and try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final trainers = ref.watch(trainersProvider);

    if (_cancelTarget != null) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _cancelTarget = null),
        child: Column(
          children: [
            Expanded(
              child: BookingCancelScreen(
                booking: _cancelTarget!,
                trainers: trainers,
                onBack: () => setState(() => _cancelTarget = null),
                onConfirmCancel: _confirmCancel,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
              ),
          ],
        ),
      );
    }

    final info = ref.watch(clientInfoProvider);
    final settings = ref.watch(platformSettingsProvider);
    final bookings = ref.watch(clientBookingsProvider).where((b) => b.clientId == info.id).toList();
    final today = isoToday();

    final future = bookings.where((b) => b.date.compareTo(today) >= 0).toList()
      ..sort((a, b) => (a.date + a.slot.toString().padLeft(4, '0')).compareTo(b.date + b.slot.toString().padLeft(4, '0')));

    Trainer? trainerFor(Booking b) {
      final matches = trainers.where((t) => t.id == b.trainerId);
      return matches.isNotEmpty ? matches.first : null;
    }

    bool canRescheduleNow(Booking b) => canReschedule(
          b,
          blockRescheduleInWindow: settings.blockRescheduleInWindow,
          lateCancellationHours: settings.lateCancellationHours,
          noShowCancelHours: settings.noShowCancelHours,
        );

    // Back from Past Visits returns to Future Visits before leaving the page.
    return LocalBackScope(
      isOpen: _tab == "past",
      onBack: () => setState(() => _tab = "future"),
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: widget.onBack, title: "Profile Settings"),
          const SizedBox(height: 10),
          const SectionLabel("Visits"),
          Row(
            children: [
              Expanded(
                child: _VisitsTab(
                  label: "Future Visits",
                  selected: _tab == "future",
                  onTap: () => setState(() => _tab = "future"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _VisitsTab(
                  label: "Past Visits",
                  selected: _tab == "past",
                  onTap: () => setState(() => _tab = "past"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_tab == "future")
            if (future.isEmpty)
              const HintBox(text: "No upcoming sessions booked.")
            else
              ...future.map(
                (b) => _FutureVisitCard(
                  booking: b,
                  trainer: trainerFor(b),
                  reschedulable: canRescheduleNow(b),
                  charged: cancelWindow(
                        b,
                        lateCancellationHours: settings.lateCancellationHours,
                        noShowCancelHours: settings.noShowCancelHours,
                      ) !=
                      "free",
                  onReschedule: () => widget.onReschedule(b),
                  onCancel: () => setState(() => _cancelTarget = b),
                ),
              )
          else
            // U6: the full past-sessions list lives in History only.
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Your past sessions are all in one place: History.",
                    style: TextStyle(fontSize: 13, color: AppColors.txt),
                  ),
                  const SizedBox(height: 10),
                  BtnGhost(
                    key: const Key("visits-open-history"),
                    full: true,
                    onPressed: widget.onOpenHistory,
                    child: const Text("See past sessions in History →"),
                  ),
                ],
              ),
            ),
          if (_credits.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionLabel("Single sessions you've bought"),
            for (final c in _credits) _SingleSessionRow(credit: c),
          ],
        ],
      ),
      ),
    );
  }
}

class _VisitsTab extends StatelessWidget {
  const _VisitsTab({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapHighlight(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.gold : AppColors.card,
          border: Border.all(color: selected ? AppColors.gold : AppColors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? AppColors.onGold : AppColors.mute,
          ),
        ),
      ),
    );
  }
}

class _FutureVisitCard extends StatelessWidget {
  const _FutureVisitCard({
    required this.booking,
    required this.trainer,
    required this.reschedulable,
    required this.charged,
    required this.onReschedule,
    required this.onCancel,
  });

  final Booking booking;
  final Trainer? trainer;
  final bool reschedulable;
  final bool charged;
  final VoidCallback onReschedule;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${dayLabel(b.date)} · ${fmtSlot(b.slot)}",
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(trainer?.displayTitle ?? "Removed", style: TextStyle(fontSize: 12, color: AppColors.mute)),
                  if (charged)
                    Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        "⚠ Late cancel fee window",
                        style: TextStyle(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              color: AppColors.card,
              onSelected: (v) => v == "reschedule" ? onReschedule() : onCancel(),
              itemBuilder: (context) => [
                if (reschedulable)
                  PopupMenuItem(
                    value: "reschedule",
                    child: Text("Reschedule", style: TextStyle(color: AppColors.txt, fontSize: 13)),
                  ),
                PopupMenuItem(
                  value: "cancel",
                  child: Text(
                    charged ? "Late Cancel" : "Cancel",
                    style: TextStyle(color: AppColors.errorText, fontSize: 13),
                  ),
                ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("Edit", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.txt)),
                    SizedBox(width: 3),
                    Icon(LucideIcons.chevronDown, size: 13, color: AppColors.mute),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One purchased single session — what it cost, when it was bought, and
/// whether it is still available (a cancelled session comes back until it expires).
class _SingleSessionRow extends StatelessWidget {
  const _SingleSessionRow({required this.credit});
  final SingleSessionCredit credit;

  static String _d(DateTime d) => "${d.month}/${d.day}/${d.year}";

  @override
  Widget build(BuildContext context) {
    final c = credit;
    final String label;
    final Color color;
    if (c.status == "refunded") {
      label = "Refunded";
      color = AppColors.mute;
    } else if (c.bookingId != null) {
      label = "Booked";
      color = AppColors.grn;
    } else if (!c.expiresAt.isAfter(DateTime.now())) {
      label = "Expired";
      color = AppColors.mute;
    } else {
      label = "Available";
      color = AppColors.gold;
    }
    final price = c.priceCents <= 0 ? "Free" : "\$${(c.priceCents / 100).toStringAsFixed(c.priceCents % 100 == 0 ? 0 : 2)}";
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Single Session — ${sessionTypeLabel(c.sessionType)}", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text("$price · bought ${_d(c.purchasedAt)}", style: TextStyle(fontSize: 12, color: AppColors.mute)),
                  if (c.status == "active" && c.bookingId == null && c.expiresAt.isAfter(DateTime.now()))
                    Text("Use it by ${_d(c.expiresAt)}", style: TextStyle(fontSize: 12, color: AppColors.mute)),
                ],
              ),
            ),
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
