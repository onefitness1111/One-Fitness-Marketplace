import "../../data/models/booking.dart";
import "../../data/models/trainer.dart";
import "membership_utils.dart";
import "unavailability.dart";

/// Who may save or delete a coach's unavailability.
///
/// A coach may only change their own. The owner may change any coach's.
/// Another coach is refused. This is the same rule the
/// `apply_coach_unavailability` database function enforces.
bool mayEditUnavailability({
  required String role,
  required String callerId,
  required String trainerId,
}) {
  if (role == "owner") return true;
  if (role == "coach" && callerId == trainerId) return true;
  return false;
}

class UnavailabilityDenied implements Exception {
  const UnavailabilityDenied();
  @override
  String toString() => "You can only set unavailability for yourself.";
}

/// What one apply did. A retry of the same entry id returns this with
/// [alreadyApplied] set and does not credit or notify again.
class UnavailabilityApplyOutcome {
  const UnavailabilityApplyOutcome({
    required this.cancelledIds,
    required this.restoredPackageBookingIds,
    required this.restoredCreditIds,
    required this.notifiedClientIds,
    required this.alreadyApplied,
  });

  final List<String> cancelledIds;

  /// Package or membership bookings whose hold was released because
  /// `cancelled_at` was set. The allowance counts only rows that are not
  /// cancelled, which is how a coach cancel gives the session back.
  final List<String> restoredPackageBookingIds;

  /// Single-session credit ids whose `booking_id` was cleared. A checked-in
  /// or no-show credit is not in here.
  final List<String> restoredCreditIds;

  /// One entry per client, even when several of their sessions were cancelled
  /// and even when a semi-private session had several clients (each client
  /// is listed once). Empty on a retry.
  final List<String> notifiedClientIds;
  final bool alreadyApplied;

  UnavailabilityApplyOutcome asRetry() => UnavailabilityApplyOutcome(
        cancelledIds: cancelledIds,
        restoredPackageBookingIds: restoredPackageBookingIds,
        restoredCreditIds: restoredCreditIds,
        notifiedClientIds: const [],
        alreadyApplied: true,
      );
}

/// In-memory stand-in for the database function, so the auth rule, the
/// one-time credit restore, and the one-time notify can be tested without
/// a database. The SQL function follows these same steps.
class UnavailabilityApply {
  final Map<String, UnavailabilityApplyOutcome> _done = {};
  final Map<String, String?> creditBooking = {};
  final Set<String> cancelled = {};
  final List<String> packageRestoreLog = [];

  UnavailabilityApplyOutcome apply({
    required String role,
    required String callerId,
    required String trainerId,
    required TrainerUnavailability entry,
    required List<Booking> bookings,
  }) {
    if (!mayEditUnavailability(role: role, callerId: callerId, trainerId: trainerId)) {
      throw const UnavailabilityDenied();
    }
    final prior = _done[entry.id];
    if (prior != null) return prior.asRetry();

    final hits = bookingsHitByUnavailability(entry, bookings, trainerId: trainerId);
    final cancelledIds = <String>[];
    final packages = <String>[];
    final credits = <String>[];
    final clients = <String>{};

    for (final b in hits) {
      if (cancelled.contains(b.id)) continue;
      cancelled.add(b.id);
      cancelledIds.add(b.id);
      clients.add(b.clientId);
      final plan = b.planId ?? "";
      if (plan.startsWith("single:")) {
        final creditId = plan.substring(7);
        if (creditBooking[creditId] == b.id) {
          creditBooking[creditId] = null;
          credits.add(creditId);
        }
      } else if (plan.isNotEmpty && !b.isPhysicalAssessment && !sessionIsConsumed(b.attendanceStatus)) {
        packageRestoreLog.add(b.id);
        packages.add(b.id);
      }
    }

    final outcome = UnavailabilityApplyOutcome(
      cancelledIds: cancelledIds,
      restoredPackageBookingIds: packages,
      restoredCreditIds: credits,
      notifiedClientIds: clients.toList(),
      alreadyApplied: false,
    );
    _done[entry.id] = outcome;
    return outcome;
  }
}
