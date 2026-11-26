import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/widgets/calendar_sync_section.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/providers/trainer_providers.dart";

/// The staff "Calendar Sync" page (U13). Reached from the coach menu and
/// the Schedule card.
///
/// A coach gets the sessions they run. The owner gets the sessions the
/// owner runs personally (bookings whose trainer is the owner's own
/// profile) — never every coach's sessions, and never a blank page.
class CalendarSyncPage extends ConsumerWidget {
  const CalendarSyncPage({super.key, this.ownerProfileIdOverride});

  /// Tests pass the owner's profile id; the app reads the signed-in user.
  final String? ownerProfileIdOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(trainerAuthProvider);
    final isOwner = auth == "owner";
    final myId = isOwner ? (ownerProfileIdOverride ?? _signedInId()) : auth;
    final bookings = ref.watch(allBookingsProvider);
    final upcoming = calendarFeedPreview(bookings, trainerId: myId, today: isoToday());
    final roster = ref.watch(trainerRosterProvider);
    String clientName(String id) {
      for (final c in roster) {
        if (c.id == id) return c.name;
      }
      return "Client";
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CalendarSyncSection(),
          const SizedBox(height: 16),
          SectionLabel(isOwner ? "Your own sessions in this calendar" : "Sessions in this calendar"),
          Text(
            isOwner
                ? "Only sessions you run yourself are added — not every coach's."
                : "The sessions you're running. Changes follow automatically.",
            style: TextStyle(fontSize: 11, color: AppColors.mute),
          ),
          const SizedBox(height: 8),
          if (upcoming.isEmpty)
            const HintBox(text: "No upcoming sessions yet.")
          else
            for (final b in upcoming)
              AppCard(
                key: Key("calendar-preview-${b.id}"),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${sessionTypeLabel(b.sessionType)} · ${disciplineLabel(b.discipline)}",
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "${dayLabel(b.date)} · ${fmtSlot(b.slot)} · ${clientName(b.clientId)}",
                      style: TextStyle(fontSize: 12, color: AppColors.mute),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

String? _signedInId() {
  try {
    final id = SupabaseService.currentUser?.id;
    return (id == null || id.isEmpty) ? null : id;
  } catch (_) {
    return null;
  }
}

/// What the calendar feed will carry for [trainerId], soonest first, the
/// same scope as `calendar-feed` (trainer_id = this person, not cancelled).
List<Booking> calendarFeedPreview(
  List<Booking> bookings, {
  required String? trainerId,
  required String today,
  int limit = 20,
}) {
  if (trainerId == null || trainerId.isEmpty) return const [];
  final rows = bookings
      .where((b) => b.trainerId == trainerId && b.status != "cancelled" && b.date.compareTo(today) >= 0)
      .toList()
    ..sort((a, b) {
      final d = a.date.compareTo(b.date);
      return d != 0 ? d : a.slot.compareTo(b.slot);
    });
  return rows.length > limit ? rows.sublist(0, limit) : rows;
}
