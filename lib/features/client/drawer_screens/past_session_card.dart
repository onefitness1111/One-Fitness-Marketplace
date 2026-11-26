import "package:flutter/material.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_utils.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/trainer.dart";

/// Every past session, newest first — booked sessions with their
/// attendance outcome. Shown in one place only, History (U6); Profile
/// Settings > Visits and the Dashboard calendar link there.
List<Booking> pastSessionsNewestFirst(List<Booking> bookings, {required String clientId, required String today}) {
  final past = bookings.where((b) => b.clientId == clientId && b.date.compareTo(today) < 0).toList()
    ..sort((a, b) => (b.date + b.slot.toString().padLeft(4, '0')).compareTo(a.date + a.slot.toString().padLeft(4, '0')));
  return past;
}

/// One past session: type, coach name, when, and how attendance was marked.
class PastSessionCard extends StatelessWidget {
  const PastSessionCard({super.key, required this.booking, required this.trainer});

  final Booking booking;
  final Trainer? trainer;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final matches = kAttendanceOptions.where((o) => o.key == b.attendanceStatus);
    final opt = matches.isNotEmpty ? matches.first : null;
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
                    "${sessionTypeLabel(b.sessionType)} · ${disciplineLabel(b.discipline)}",
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  const SizedBox(height: 3),
                  Text(trainer?.displayTitle ?? "Removed", style: TextStyle(fontSize: 12, color: AppColors.mute)),
                  const SizedBox(height: 3),
                  Text(
                    "${dayLabel(b.date)} · ${fmtSlot(b.slot)}",
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: opt?.color ?? AppColors.line),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                opt?.label ?? "Unmarked",
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: opt?.color ?? AppColors.mute),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
