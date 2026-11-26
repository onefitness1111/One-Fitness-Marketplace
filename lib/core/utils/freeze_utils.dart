import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/client_plan.dart";
import "../../data/models/membership_plan.dart";
import "date_utils.dart";
import "membership_utils.dart" show bookingOccupiesLimit;

/// Membership freeze rules the app shows. The server has the same rules in
/// supabase/functions/_shared/membershipFreeze.mjs and the
/// block_frozen_client_booking trigger.
///
/// A freeze covers its start day up to, not including, its end day. The
/// end day is the first day the client can book again. A freeze the owner
/// set for a later start day is stored with the same dates but
/// membershipPaused still false until that day.

const _monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// "Dec 22" from "2026-12-22". Anything else comes back unchanged.
String freezeShortDay(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null || iso.length < 10) return iso;
  return "${_monthsShort[d.month - 1]} ${d.day}";
}

/// True when a freeze has been set up but has not started yet.
bool freezeScheduled(ClientInfo info) =>
    !info.membershipPaused && (info.membershipPausedAt ?? "").isNotEmpty;

/// When [date] is frozen, the freeze's end day ("" when it has none).
/// Null when [date] can be booked.
String? frozenUntilOn(ClientInfo info, String date) {
  final from = info.membershipPausedAt ?? "";
  final until = info.membershipFreezeEndsAt ?? "";
  if (!info.membershipPaused && from.isEmpty) return null;
  if (from.isNotEmpty && date.compareTo(from) < 0) return null;
  if (until.isNotEmpty && date.compareTo(until) >= 0) return null;
  return until;
}

/// What a client sees when they try to book a frozen day (U14).
String frozenBookingMessage(String until) => until.isEmpty
    ? "Your account is frozen. Message ONE Fitness to resume it."
    : "Your account is frozen until ${freezeShortDay(until)}. You can book sessions starting that day.";

/// The active plan entry for [plan], when its held-sessions window covers
/// [today].
ClientPlanEnrollment? activeHold(ClientInfo info, MembershipPlan plan, String today) {
  if (plan.kind != PlanKind.membership) return null;
  for (final e in info.plans) {
    if (e.planId == plan.id && e.status == "active" && e.holdActiveOn(today)) return e;
  }
  return null;
}

/// Held sessions left on [plan] and the day they run out, while the
/// window after a freeze is open. Null otherwise.
({int left, String until})? heldSessionsLeft(
  ClientInfo info,
  MembershipPlan plan,
  List<Booking> bookings, {
  String? today,
}) {
  final day = today ?? isoToday();
  final hold = activeHold(info, plan, day);
  if (hold == null) return null;
  final rollover = hold.rolloverMonth == day.substring(0, 7) && hold.rolloverSessions > 0 ? hold.rolloverSessions : 0;
  final total = (hold.heldSessions ?? 0) + rollover;
  var booked = 0;
  for (final b in bookings) {
    if (b.clientId != info.id || b.planId != plan.id) continue;
    if (!bookingOccupiesLimit(b)) continue;
    if (hold.inHoldWindow(b.date)) booked++;
  }
  final left = total - booked;
  return (left: left < 0 ? 0 : left, until: hold.heldUntil!);
}

/// "3 sessions left until Dec 21".
String heldSessionsLine(int left, String until) =>
    "$left ${left == 1 ? "session" : "sessions"} left until ${freezeShortDay(until)}";

/// The held-sessions line from plan entries alone, for right after an
/// unfreeze, before bookings are reloaded. Null when nothing is held.
String? heldSessionsLineFromPlans(List<ClientPlanEnrollment> plans, {String? today}) {
  final day = today ?? isoToday();
  for (final e in plans) {
    if (e.status != "active" || !e.holdActiveOn(day)) continue;
    final rollover = e.rolloverMonth == day.substring(0, 7) && e.rolloverSessions > 0 ? e.rolloverSessions : 0;
    return heldSessionsLine((e.heldSessions ?? 0) + rollover, e.heldUntil!);
  }
  return null;
}
