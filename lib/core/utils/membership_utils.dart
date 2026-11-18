import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/membership_plan.dart";
import "date_utils.dart";

/// Session-accounting helpers ported from src/lib/helpers.js and
/// src/data/membershipPlans.js — trimmed to what the client dashboard needs.

/// Early and late cancels do not use a session. The spot goes back to the
/// client's balance and to their booking limit immediately. A late-cancel
/// fee, when there is one, is money — it is not part of this count.
const kGiveBackAttendanceStatuses = {"early-cancel", "late-cancel"};

/// A session is used up only when the client is checked in or marked as a
/// no-show. Booking it does not use it.
const kConsumingAttendanceStatuses = {"checked-in", "no-show"};

/// True when this attendance has used the session up.
bool sessionIsConsumed(String? attendance) =>
    kConsumingAttendanceStatuses.contains(attendance);

/// True when the booking still counts toward how many sessions the client
/// may have on the books at once. A future booking holds a spot but is not
/// used up. A check-in or no-show holds a spot too, because it has been used,
/// and it is counted once — never both as "booked" and as "used".
bool bookingOccupiesLimit(Booking b) =>
    !b.isPhysicalAssessment &&
    b.status != "cancelled" &&
    !kGiveBackAttendanceStatuses.contains(b.attendanceStatus);

/// Every membership or package the client currently holds, in the order
/// booking should draw on them: the recurring membership first (its sessions
/// reset monthly, so unused ones are lost), then packages oldest-first (a
/// lifetime balance keeps).
///
/// A client can hold one recurring membership plus any number of one-time
/// packages at the same time. `membershipPlanId` is only the subscription
/// slot — the one that cancel/freeze/change operate on — so reading it alone
/// misses every package bought alongside. Programs are deliberately not
/// here: they grant programming, not sessions (see isProgramKind).
List<MembershipPlan> heldAccessPlans(ClientInfo info, List<MembershipPlan> allPlans) {
  final byId = {for (final p in allPlans) p.id: p};
  final seen = <String>{};
  final held = <MembershipPlan>[];
  void add(String? id) {
    final p = id == null ? null : byId[id];
    if (p == null || isProgramKind(p.kind) || !seen.add(p.id)) return;
    held.add(p);
  }

  final today = isoToday();

  // The plan in the subscription slot, unless its own enrolment says it has
  // expired.
  //
  // This used to be added unconditionally, which meant an expiry date set on
  // the client's main plan did nothing at all — staff could give someone
  // access "until March" and they would keep booking indefinitely. The
  // enrolment list below was already checked; the slot was the hole.
  final slotEnrolment = info.plans
      .where((e) => e.planId == info.membershipPlanId && e.status == "active");
  final slotExpiry = slotEnrolment.isEmpty ? null : slotEnrolment.first.endsAt;
  if (slotExpiry == null || today.compareTo(slotExpiry) <= 0) {
    add(info.membershipPlanId);
  }

  // A plan the client switched away from keeps its remaining sessions until
  // the period they already paid for runs out (endsAt) — after that it's
  // spent, and only whatever rolled over lives on under the new plan.
  final enrolled = [
    ...info.plans.where((e) => e.status == "active" && (e.endsAt == null || today.compareTo(e.endsAt!) <= 0)),
  ]..sort((a, b) => a.startDate.compareTo(b.startDate));
  for (final e in enrolled) {
    add(e.planId);
  }
  // Memberships ahead of packages, keeping start-date order within each —
  // a partition rather than a sort, because List.sort isn't stable.
  return [
    ...held.where((p) => p.kind == PlanKind.membership),
    ...held.where((p) => p.kind != PlanKind.membership),
  ];
}

/// The held plan a staff-made booking should be charged to, or null when
/// the client holds nothing that covers [sessionType].
///
/// Same preference as canBookOffering — membership before packages, first
/// with budget wins — but with one difference: staff can knowingly book a
/// client past their balance, so if every covering plan is spent, the first
/// covering plan is still returned and simply goes over. What must never
/// happen is the booking landing with no plan at all while the client does
/// hold one; that's a session silently not deducted.
String? planToChargeFor(
  ClientInfo info,
  String sessionType,
  List<Booking> bookings,
  List<MembershipPlan> allPlans,
) {
  final covering = heldAccessPlans(info, allPlans)
      .where((p) => sessionType == "large-group" || p.allowedTypes.contains(sessionType))
      .toList();
  if (covering.isEmpty) return null;
  for (final p in covering) {
    if (sessionsTowardBookingLimit(info, p, bookings) < effectiveMaxSessions(info, p)) return p.id;
  }
  return covering.first.id;
}

/// Bookings that belong to [plan] for this client. A row that recorded its
/// plan at booking time counts only for that plan. Older rows have no plan
/// and fall back to any plan that covers their session type.
Iterable<Booking> _planBookings(ClientInfo info, MembershipPlan plan, List<Booking> bookings) {
  final mine = bookings.where((b) =>
      b.clientId == info.id &&
      (b.planId == null ? plan.allowedTypes.contains(b.sessionType) : b.planId == plan.id) &&
      (b.planId == null || !b.planId!.startsWith("single:")));
  if (plan.kind == PlanKind.membership) {
    final thisMonth = isoToday().substring(0, 7);
    return mine.where((b) => b.date.substring(0, 7) == thisMonth);
  }
  return mine;
}

/// Sessions used up this period: checked in or no-show only.
///
/// A booking does not reduce this. An early cancel or a late cancel does
/// not either — the session is back on the balance as soon as it is cancelled.
int sessionsUsedThisPeriod(ClientInfo info, MembershipPlan plan, List<Booking> bookings) =>
    _planBookings(info, plan, bookings).where((b) => sessionIsConsumed(b.attendanceStatus)).length;

/// How many sessions currently count against the booking limit: every
/// booking that is not an early or late cancel. Checked-in and no-show
/// count once here (they are used). A future booking counts once here and
/// not at all in [sessionsUsedThisPeriod].
int sessionsTowardBookingLimit(ClientInfo info, MembershipPlan plan, List<Booking> bookings) =>
    _planBookings(info, plan, bookings).where(bookingOccupiesLimit).length;

/// Sessions still on the balance — not yet checked in or marked no-show.
int sessionsRemainingBalance(ClientInfo info, MembershipPlan plan, List<Booking> bookings) {
  final max = effectiveMaxSessions(info, plan);
  return (max - sessionsUsedThisPeriod(info, plan, bookings)).clamp(0, max);
}

/// How many more sessions the client may book right now.
int sessionsLeftToBook(ClientInfo info, MembershipPlan plan, List<Booking> bookings) {
  final max = effectiveMaxSessions(info, plan);
  return (max - sessionsTowardBookingLimit(info, plan, bookings)).clamp(0, max);
}

/// Mirrors lib/helpers.js `effectiveMaxSessions` — a membership-kind plan's
/// override goes stale once the calendar rolls into a new month from the
/// one it was set in (sessionCountOverrideMonth), falling back to the
/// plan's own default; a package's override has no month stamp and stays
/// permanent.
int effectiveMaxSessions(ClientInfo info, MembershipPlan plan) {
  final override = info.sessionCountOverride;
  var base = plan.maxSessions ?? 0;
  if (override != null) {
    final month = info.sessionCountOverrideMonth;
    final stale = plan.kind == PlanKind.membership && month != null && month != isoToday().substring(0, 7);
    if (!stale) base = override;
  }
  return base + rolloverSessionsFor(info, plan);
}

/// Sessions carried into THIS month from last month's leftovers under the
/// plan's roll-over rule. Written at renewal (stripe-webhook) and good for
/// that month only, so an unused carry-over never compounds.
int rolloverSessionsFor(ClientInfo info, MembershipPlan plan) {
  if (plan.kind != PlanKind.membership) return 0;
  final thisMonth = isoToday().substring(0, 7);
  for (final e in info.plans) {
    if (e.planId == plan.id && e.status == "active" && e.rolloverMonth == thisMonth) {
      return e.rolloverSessions;
    }
  }
  return 0;
}

const _months = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
];

class TermRenewal {
  const TermRenewal({required this.renewsLabel, required this.termMonths});
  final String renewsLabel;
  final int termMonths;
}

/// Mirrors lib/helpers.js `termRenewal` — rolls forward in whole terms from
/// the plan start date until the term containing today, returning that
/// term's end (= next renewal) date.
TermRenewal? termRenewal(String startDateISO, int termMonths) {
  if (termMonths <= 0) return null;
  var end = DateTime.parse(startDateISO);
  final now = DateTime.parse(isoToday());
  while (!end.isAfter(now)) {
    end = DateTime(end.year, end.month + termMonths, end.day);
  }
  return TermRenewal(
    renewsLabel: "${_months[end.month - 1]} ${end.day}, ${end.year}",
    termMonths: termMonths,
  );
}

/// Whether [plan] is on sale on [today] (ISO yyyy-MM-dd).
///
/// A plan carries an optional sales window: `startDate` is the first day it
/// can be bought, `endDate` the last. Outside it the plan is hidden from the
/// Access Hub and refused by the purchase paths.
///
/// This is deliberately only about selling. Clients already holding the plan
/// keep their access, keep their session allowance and keep booking, and a
/// membership carries on renewing — closing a plan to new sales is a
/// merchandising decision, not a reason to cut off people who are paying.
/// Both ends are inclusive: a plan sold "until 31 Dec" is still on sale on
/// the 31st.
bool planOnSale(MembershipPlan plan, String today) {
  final from = (plan.startDate ?? "").trim();
  if (from.isNotEmpty && today.compareTo(from) < 0) return false;
  final until = (plan.endDate ?? "").trim();
  if (until.isNotEmpty && today.compareTo(until) > 0) return false;
  return true;
}

/// What a plan's session allowance is counted against — the two kinds mean
/// different things by the same number, and the editor used to just say
/// "Max sessions".
String sessionAllowanceLabel(PlanKind kind) =>
    kind == PlanKind.membership ? "Sessions per month" : "Sessions included";
