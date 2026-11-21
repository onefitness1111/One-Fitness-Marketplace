import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_limits.dart";

/// Mirrors OverridePrompt.jsx. An owner pushing past a real conflict or a
/// full class sees what they're overriding before it's stamped on the booking.
Future<bool> confirmOwnerOverride(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text("Cancel"),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text("Override"),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Whether to insert again with an owner stamp.
class OverrideRetry {
  const OverrideRetry({this.reason, this.declined = false});

  /// Set when the owner confirmed. Starts with "conflict" or "capacity"
  /// and then names what was in the way.
  final String? reason;

  /// They were asked and said no. Don't add a second error under that.
  final bool declined;

  bool get go => reason != null;
}

/// Asks the owner to book over a trigger refusal.
///
/// Returns an empty result when this isn't an override case (a coach, a
/// network failure, or a refusal that isn't the booking-limit trigger) so
/// the caller can show the real sentence. [unspecifiedFull] covers a
/// single-session call that came back "full" without the trigger text —
/// the edge function drops that sentence.
Future<OverrideRetry> offerBookingOverride(
  BuildContext context, {
  required Object error,
  required bool isOwner,
  required bool alreadyOverriding,
  required String coachName,
  required String addingClientName,
  int? conflictSlot,
  String? conflictingClientName,
  int? capacityCount,
  int? capacityCap,
  bool unspecifiedFull = false,
  bool refunded = false,
}) async {
  if (!isOwner || alreadyOverriding) return const OverrideRetry();
  if (!context.mounted) return const OverrideRetry(declined: true);

  final kind = classifyBookingLimitError(error);
  final String title;
  final String message;
  final String reason;
  if (kind == BookingLimitKind.overlap) {
    title = "Scheduling conflict";
    message = ownerOverlapOverrideMessage(
      coachName: coachName,
      conflictSlot: conflictSlot,
      clientName: conflictingClientName,
    );
    reason = overrideReasonFor(
      BookingLimitKind.overlap,
      detail: overrideDetail(message),
    );
  } else if (kind == BookingLimitKind.capacity) {
    final parsed = capacityPairFromError(error);
    title = "Session at capacity";
    message = ownerCapacityOverrideMessage(
      clientName: addingClientName,
      count: parsed?.$1 ?? capacityCount,
      cap: parsed?.$2 ?? capacityCap,
    );
    reason = overrideReasonFor(
      BookingLimitKind.capacity,
      detail: overrideDetail(message),
    );
  } else if (unspecifiedFull) {
    title = "Scheduling conflict";
    message = conflictSlot != null
        ? ownerOverlapOverrideMessage(
            coachName: coachName,
            conflictSlot: conflictSlot,
            clientName: conflictingClientName,
          )
        : ownerUnspecifiedLimitMessage;
    reason = conflictSlot != null
        ? overrideReasonFor(
            BookingLimitKind.overlap,
            detail: overrideDetail(message),
          )
        : "schedule limit — ${overrideDetail(message)}";
  } else {
    return const OverrideRetry();
  }

  final shown = refunded ? "The charge was refunded. $message" : message;
  final ok = await confirmOwnerOverride(context, title: title, message: shown);
  if (!ok) return const OverrideRetry(declined: true);
  if (refunded) {
    final base = reason.endsWith(".") ? reason : "$reason.";
    return OverrideRetry(reason: "$base The charge was refunded.");
  }
  return OverrideRetry(reason: reason);
}
