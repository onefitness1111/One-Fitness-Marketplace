import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:shared_preferences/shared_preferences.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/late_fee_notice.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/utils/rebook.dart";
import "../../../core/widgets/app_buttons.dart";
import "../../../core/widgets/app_card.dart";
import "../../../data/models/booking.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/platform_settings_provider.dart";
import "../../../data/providers/trainer_providers.dart";

/// After a session has ended: one tap books the same coach and time next
/// week, when that slot is open. Hidden when it is not.
class RebookOfferCard extends ConsumerStatefulWidget {
  const RebookOfferCard({super.key});

  @override
  ConsumerState<RebookOfferCard> createState() => _RebookOfferCardState();
}

class _RebookOfferCardState extends ConsumerState<RebookOfferCard> {
  bool _busy = false;
  String? _error;
  String? _hiddenId;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _hiddenId = prefs.getString("rebook-hidden"));
    });
  }

  Future<void> _hide(String bookingId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("rebook-hidden", bookingId);
    if (mounted) setState(() => _hiddenId = bookingId);
  }

  Future<void> _book(RebookAvailability offer) async {
    if (_busy || !offer.open || offer.date == null) return;
    final info = ref.read(clientInfoProvider);
    final blocked = await bookingBlockMessage(info.id);
    if (blocked != null) {
      if (mounted) setState(() => _error = blocked);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await SupabaseService.insertBooking(Booking(
        id: "",
        clientId: info.id,
        trainerId: offer.trainerId,
        date: offer.date!,
        slot: offer.slot,
        sessionType: offer.sessionType,
        discipline: offer.discipline,
        locationName: offer.locationName,
        planId: offer.planId,
        durationMin: offer.durationMin,
      ));
      ref.read(allBookingsProvider.notifier).addBooking(saved);
      ref.read(clientBookingsProvider.notifier).addBooking(saved);
      SupabaseService.sendBookingConfirmation([saved.id]);
      SupabaseService.clientNotify("booking-confirmed", {
        "when": "${niceDate(offer.date!)} at ${fmtSlot(offer.slot)}",
      });
      notifyClientAndCoach(
        clientId: info.id,
        coachId: offer.trainerId,
        clientTitle: "Booking confirmed",
        clientBody: "You're booked for ${niceDate(offer.date!)} at ${fmtSlot(offer.slot)} with ${offer.coachName}.",
        coachTitle: "New booking",
        coachBody: "${info.name} booked ${niceDate(offer.date!)} at ${fmtSlot(offer.slot)}.",
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Booked ${niceDate(offer.date!)} at ${fmtSlot(offer.slot)} with ${offer.coachName}.")),
        );
      }
    } catch (e) {
      final text = e.toString();
      final message = text.contains("booking-limit")
          ? "You've booked all the sessions on this plan."
          : text.contains("capacity") || text.contains("overlaps")
              ? "That time was just taken."
              : "Couldn't book that time. Try again from Booking.";
      if (mounted) setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(clientInfoProvider);
    final settings = ref.watch(platformSettingsProvider);
    final offer = rebookOfferForClient(
      info: info,
      bookings: ref.watch(allBookingsProvider),
      coaches: ref.watch(trainersProvider),
      blocked: ref.watch(blockedTimesProvider),
      plans: ref.watch(membershipPlansProvider),
      now: DateTime.now(),
      record: ref.watch(clientRecordProvider),
      waivers: ref.watch(waiversProvider),
      minBookingLeadHours: settings.minBookingLeadHours,
      maxBookingHorizonDays: settings.maxBookingHorizonDays,
      semiPrivateCap: settings.semiPrivateCap,
    );
    if (!offer.open || offer.date == null || offer.sourceBookingId == _hiddenId) {
      return const SizedBox.shrink();
    }
    return AppCard(
      borderColor: AppColors.goldDim,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "BOOK THE SAME TIME NEXT WEEK",
            style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w700, letterSpacing: 0.6),
          ),
          const SizedBox(height: 6),
          Text(
            "${dayLabel(offer.date!)} · ${fmtSlot(offer.slot)}",
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 2),
          Text("with ${offer.coachName}", style: TextStyle(fontSize: 13, color: AppColors.mute)),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          BtnGold(
            onPressed: _busy ? null : () => _book(offer),
            full: true,
            child: Text(_busy ? "Booking…" : "Book the same time next week"),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.center,
            child: TextButton(
              onPressed: _busy ? null : () => _hide(offer.sourceBookingId),
              child: Text("Not now", style: TextStyle(color: AppColors.mute, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}
