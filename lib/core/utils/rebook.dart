import "../../data/models/blocked_time.dart";
import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/client_record.dart";
import "../../data/models/membership_plan.dart";
import "../../data/models/trainer.dart";
import "../../data/models/waiver_doc.dart";
import "booking_utils.dart";
import "membership_utils.dart";
import "platform_settings.dart";

/// Whether the client can book the same coach and the same time next week
/// in one tap, after a session has ended.
///
/// Uses the same rules as the booking screen: the coach still offers that
/// slot, it is not blocked or a day off, the class is not full, and
/// [canBookOffering] (lead time, how far ahead, their own clash, membership,
/// pause, restriction, sessions left). Saving the booking goes through the
/// normal insert, which takes the per-client plan lock from the session
/// allowance so two bookings cannot both sneak in.

class RebookAvailability {
  const RebookAvailability({
    required this.open,
    this.reason,
    this.message,
    this.date,
    this.planId,
    this.coachName,
    this.locationName,
    this.durationMin = 60,
    this.slot = 0,
    this.sessionType = "",
    this.discipline = "",
    this.trainerId = "",
    this.sourceBookingId = "",
  });

  final bool open;
  final String? reason;
  final String? message;

  /// The day next week, when [open].
  final String? date;
  final String? planId;

  /// Coach name only. Never a legal name.
  final String? coachName;
  final String? locationName;
  final int durationMin;
  final int slot;
  final String sessionType;
  final String discipline;
  final String trainerId;

  /// The session this offer came from. Hiding the card hides this one only.
  final String sourceBookingId;

  static const closed = RebookAvailability(open: false);
}

bool bookingWasCancelled(Booking b) =>
    b.status == "cancelled" || kGiveBackAttendanceStatuses.contains(b.attendanceStatus);

/// The session clock has finished, and it was not cancelled or a no-show.
bool bookingHasEnded(Booking b, DateTime now) {
  if (bookingWasCancelled(b) || b.attendanceStatus == "no-show") return false;
  if (b.isPhysicalAssessment) return false;
  final end = sessionStartLocal(b).add(Duration(minutes: b.durationMin));
  return !end.isAfter(now);
}

/// The client's most recently ended session, if they have one.
Booking? latestEndedSession(List<Booking> bookings, String clientId, DateTime now) {
  final ended = bookings.where((b) => b.clientId == clientId && bookingHasEnded(b, now)).toList()
    ..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.slot.compareTo(a.slot);
    });
  return ended.isEmpty ? null : ended.first;
}

RebookAvailability _closed(String reason, String message) =>
    RebookAvailability(open: false, reason: reason, message: message);

/// [waiver] is the result of [waiverGateCheck] when the caller has the
/// signed documents. Null means nothing is outstanding.
RebookAvailability rebookSameTimeNextWeek({
  required Booking session,
  required DateTime now,
  required Trainer? coach,
  required List<Booking> bookings,
  required List<BlockedTime> blocked,
  required ClientInfo info,
  required List<MembershipPlan> plans,
  BookingCheck? waiver,
  int minBookingLeadHours = kMinBookingLeadHours,
  int maxBookingHorizonDays = kMaxBookingHorizonDays,
  int semiPrivateCap = kSemiPrivateCap,
}) {
  if (session.clientId != info.id) {
    return _closed("not-yours", "That session is not on your schedule.");
  }
  if (bookingWasCancelled(session)) {
    return _closed("cancelled", "That session was cancelled.");
  }
  if (session.attendanceStatus == "no-show") {
    return _closed("no-show", "That session was marked as a no-show.");
  }
  if (session.isPhysicalAssessment) {
    return _closed("assessment", "The first visit is not a weekly session.");
  }
  if (!bookingHasEnded(session, now)) {
    return _closed("not-ended", "This session has not ended yet.");
  }
  if (coach == null) {
    return _closed("no-coach", "That coach is not on the schedule.");
  }

  final date = addDaysIso(session.date, 7);
  final coachName = coach.displayTitle;
  if (fallsInUnavailability(coach, date)) {
    return _closed("away", "$coachName is not in that day.");
  }
  if (fallsInBlockedTime(blocked, coach.id, date, session.slot, sessionLen: session.durationMin)) {
    return _closed("blocked", "That time is blocked.");
  }

  final offered = trainerOfferingsOn(coach, date).where(
    (o) => o.slot == session.slot && o.sessionType == session.sessionType && o.discipline == session.discipline,
  );
  if (offered.isEmpty) {
    return _closed("not-offered", "$coachName does not have that time next week.");
  }
  final offering = offered.first;

  final cap = capFor(session.sessionType, semiPrivateCap: semiPrivateCap);
  if (bookedCount(bookings, coach.id, date, session.slot) >= cap) {
    return _closed("full", "That time is already full.");
  }

  if (waiver != null && !waiver.ok) {
    return RebookAvailability(open: false, reason: waiver.reason ?? "waiver", message: waiver.msg, date: date, coachName: coachName);
  }

  final check = canBookOffering(
    info,
    session.sessionType,
    bookings,
    date,
    session.slot,
    plans,
    minBookingLeadHours: minBookingLeadHours,
    maxBookingHorizonDays: maxBookingHorizonDays,
  );
  if (!check.ok) {
    return RebookAvailability(
      open: false,
      reason: check.reason,
      message: check.msg,
      date: date,
      coachName: coachName,
    );
  }

  return RebookAvailability(
    open: true,
    date: date,
    planId: check.planId,
    coachName: coachName,
    locationName: offering.locationName ?? session.locationName,
    durationMin: offering.durationMin,
    slot: session.slot,
    sessionType: session.sessionType,
    discipline: session.discipline,
    trainerId: coach.id,
    sourceBookingId: session.id,
  );
}

/// Convenience for the screen: latest ended session, then the check.
/// [record] and [waivers] are optional so a caller without them skips the
/// signature gate (the booking screen still enforces it before saving when
/// they are passed).
RebookAvailability rebookOfferForClient({
  required ClientInfo info,
  required List<Booking> bookings,
  required List<Trainer> coaches,
  required List<BlockedTime> blocked,
  required List<MembershipPlan> plans,
  required DateTime now,
  ClientRecord? record,
  List<WaiverDoc> waivers = const [],
  int minBookingLeadHours = kMinBookingLeadHours,
  int maxBookingHorizonDays = kMaxBookingHorizonDays,
  int semiPrivateCap = kSemiPrivateCap,
}) {
  final session = latestEndedSession(bookings, info.id, now);
  if (session == null) return RebookAvailability.closed;
  Trainer? coach;
  for (final t in coaches) {
    if (t.id == session.trainerId) {
      coach = t;
      break;
    }
  }
  final waiver = record == null
      ? null
      : waiverGateCheck(info: info, record: record, waiverDocs: waivers);
  return rebookSameTimeNextWeek(
    session: session,
    now: now,
    coach: coach,
    bookings: bookings,
    blocked: blocked,
    info: info,
    plans: plans,
    waiver: waiver,
    minBookingLeadHours: minBookingLeadHours,
    maxBookingHorizonDays: maxBookingHorizonDays,
    semiPrivateCap: semiPrivateCap,
  );
}
