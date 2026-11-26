import "../../data/models/booking.dart";
import "../../data/models/client_info.dart";
import "../../data/models/client_plan.dart";
import "../../data/models/membership_plan.dart";

/// Session rollover and per-plan overrides.
///
/// The same rules live in supabase/functions/_shared/membershipRollover.mjs,
/// which is what the month-end job and the enroll path actually run. These
/// two copies have to agree: the app shows the number the job wrote.

const _consumed = {"checked-in", "no-show"};

/// "YYYY-MM" before [yyyyMm]. January wraps to December of the previous year.
String previousMonth(String yyyyMm) {
  final parts = yyyyMm.split("-");
  final y = int.parse(parts[0]);
  final m = int.parse(parts[1]);
  final prev = DateTime.utc(y, m - 1, 1);
  final mm = prev.month.toString().padLeft(2, "0");
  return "${prev.year}-$mm";
}

ClientPlanEnrollment? activeEnrollment(ClientInfo info, String planId) {
  for (final e in info.plans) {
    if (e.planId == planId && e.status == "active") return e;
  }
  return null;
}

/// Memberships this client is on right now, slot first, then the rest.
List<MembershipPlan> activeMembershipPlans(ClientInfo info, List<MembershipPlan> all) {
  final byId = {for (final p in all) p.id: p};
  final ids = <String>[];
  void add(String? id) {
    if (id == null || ids.contains(id)) return;
    final plan = byId[id];
    if (plan == null || plan.kind != PlanKind.membership) return;
    final enrolled = info.plans.any((e) => e.planId == id && e.status == "active");
    if (info.membershipPlanId == id || enrolled) ids.add(id);
  }

  add(info.membershipPlanId);
  for (final e in info.plans) {
    if (e.status == "active") add(e.planId);
  }
  return [for (final id in ids) byId[id]!];
}

/// How many unused sessions this client may carry on [plan].
///
/// A number on the plan entry wins, including 0. Otherwise the membership's
/// own limit is used, and a membership that does not roll sessions over
/// allows none.
int rolloverCap(MembershipPlan plan, ClientPlanEnrollment? enrollment) {
  if (plan.kind != PlanKind.membership) return 0;
  final custom = enrollment?.rolloverMaxOverride;
  if (custom != null) return custom < 0 ? 0 : custom;
  if (!plan.rolloverEnabled) return 0;
  return plan.rolloverMaxVisits < 0 ? 0 : plan.rolloverMaxVisits;
}

/// Base allowance for [month] ("YYYY-MM"): the plan count, or this client's
/// override for this plan. Sessions already rolled into that month are not
/// included — those expire with the month and must not be counted again
/// when deciding what rolls into the next month.
///
/// [legacyOverride] is the old client-wide column. It counts only when
/// [legacyApplies] is true, which callers set for the plan currently in the
/// client's membership slot, and only when the plan entry has no override
/// of its own.
int baseSessionAllowance({
  required MembershipPlan plan,
  ClientPlanEnrollment? enrollment,
  required String month,
  int? legacyOverride,
  String? legacyMonth,
  bool legacyApplies = false,
}) {
  var base = plan.maxSessions ?? 0;
  if (base < 0) base = 0;
  var override = enrollment?.maxSessionsOverride;
  var overrideMonth = enrollment?.maxSessionsOverrideMonth;
  if (override == null && legacyApplies) {
    override = legacyOverride;
    overrideMonth = legacyMonth;
  }
  if (override != null) {
    final stale = plan.kind == PlanKind.membership &&
        overrideMonth != null &&
        overrideMonth.isNotEmpty &&
        overrideMonth != month;
    if (!stale) base = override < 0 ? 0 : override;
  }
  return base;
}

/// Allowance for [month]: [baseSessionAllowance] plus sessions already
/// rolled into that month. Use this to show what the client can use now.
/// Month-end rollover uses [baseSessionAllowance] so a carry-over cannot
/// be rolled a second time.
int sessionAllowance({
  required MembershipPlan plan,
  ClientPlanEnrollment? enrollment,
  required String month,
  int? legacyOverride,
  String? legacyMonth,
  bool legacyApplies = false,
}) {
  var base = baseSessionAllowance(
    plan: plan,
    enrollment: enrollment,
    month: month,
    legacyOverride: legacyOverride,
    legacyMonth: legacyMonth,
    legacyApplies: legacyApplies,
  );
  if (plan.kind == PlanKind.membership && enrollment?.rolloverMonth == month) {
    final extra = enrollment!.rolloverSessions;
    base += extra < 0 ? 0 : extra;
  }
  return base;
}

bool sessionOverrideIsSet(ClientInfo info, MembershipPlan plan, String month) {
  final enrollment = activeEnrollment(info, plan.id);
  final onPlan = enrollment?.maxSessionsOverride;
  if (onPlan != null) {
    final stale = plan.kind == PlanKind.membership &&
        enrollment!.maxSessionsOverrideMonth != null &&
        enrollment.maxSessionsOverrideMonth!.isNotEmpty &&
        enrollment.maxSessionsOverrideMonth != month;
    if (!stale) return true;
  }
  if (info.membershipPlanId == plan.id && info.sessionCountOverride != null) {
    final monthStamp = info.sessionCountOverrideMonth;
    final stale = plan.kind == PlanKind.membership &&
        monthStamp != null &&
        monthStamp.isNotEmpty &&
        monthStamp != month;
    if (!stale) return true;
  }
  return false;
}

/// Checked-in and no-show sessions on [planId] in [month]. A booking that
/// was never attended does not use a session. Cancels do not either.
int consumedSessions(List<Booking> bookings, String planId, String month) {
  var n = 0;
  for (final b in bookings) {
    final id = b.planId;
    if (id == null || id != planId || id.startsWith("single:")) continue;
    if (b.status == "cancelled" || b.isPhysicalAssessment) continue;
    if (!_consumed.contains(b.attendanceStatus)) continue;
    if (!b.date.startsWith(month)) continue;
    n++;
  }
  return n;
}

/// The base stored for a "remaining sessions" edit.
///
/// The field shows what is left, which already includes sessions rolled
/// into this month. The override itself is the base, and rollover is added
/// on top, so the rolled sessions are taken back out before saving.
int overrideBaseForRemaining({
  required int desiredRemaining,
  required int used,
  required int rollover,
}) {
  final base = desiredRemaining + used - rollover;
  return base < 0 ? 0 : base;
}

/// True when any day of [month] ("YYYY-MM") was frozen, or covered by
/// sessions held from a freeze. Mirrors monthTouchedByFreeze in
/// supabase/functions/_shared/membershipFreeze.mjs.
bool monthTouchedByFreeze(String month, ClientPlanEnrollment? enrollment, ClientInfo info) {
  final parts = month.split("-");
  final y = int.parse(parts[0]);
  final m = int.parse(parts[1]);
  final first = "$month-01";
  final next = DateTime.utc(y, m + 1, 1);
  final after = "${next.year}-${next.month.toString().padLeft(2, "0")}-01";
  bool overlaps(String? from, String? until) {
    if (from == null || from.isEmpty) return false;
    final end = (until == null || until.isEmpty) ? "9999-12-31" : until;
    return from.compareTo(after) < 0 && end.compareTo(first) > 0;
  }

  if (enrollment != null && overlaps(enrollment.frozenFrom, enrollment.heldUntil ?? enrollment.heldFrom)) return true;
  final from = info.membershipPausedAt;
  if (info.membershipPaused && (from == null || from.isEmpty)) return true;
  return overlaps(from, info.membershipFreezeEndsAt);
}

/// One membership's rollover into [newMonth]. Null when this entry should
/// be left alone (not a membership, not active yet, already rolled, or the
/// plan had ended).
ClientPlanEnrollment? rollMembershipMonth({
  required MembershipPlan plan,
  required ClientPlanEnrollment enrollment,
  required List<Booking> bookings,
  required String newMonth,
  int? legacyOverride,
  String? legacyMonth,
  bool legacyApplies = false,
  bool frozen = false,
}) {
  if (plan.kind != PlanKind.membership) return null;
  if (enrollment.status != "active") return null;
  if (enrollment.rolloverMonth == newMonth) return null;
  final prev = previousMonth(newMonth);
  final start = enrollment.startDate.length >= 7 ? enrollment.startDate.substring(0, 7) : "";
  if (start.isNotEmpty && start.compareTo(prev) > 0) return null;
  final ends = enrollment.endsAt;
  if (ends != null && ends.isNotEmpty && ends.compareTo("$newMonth-01") < 0) return null;
  // A month frozen for any part, or covered by sessions held from a
  // freeze, rolls nothing (see [monthTouchedByFreeze]).
  if (frozen) return enrollment.copyWith(rolloverSessions: 0, rolloverMonth: newMonth);
  // Unused of this month's own allowance only. Sessions already rolled
  // into [prev] expire with that month and are not carried again.
  final allowance = baseSessionAllowance(
    plan: plan,
    enrollment: enrollment,
    month: prev,
    legacyOverride: legacyOverride,
    legacyMonth: legacyMonth,
    legacyApplies: legacyApplies,
  );
  final used = consumedSessions(bookings, enrollment.planId, prev);
  final unused = allowance - used;
  final cap = rolloverCap(plan, enrollment);
  final rolled = unused < 0 ? 0 : (unused < cap ? unused : cap);
  return enrollment.copyWith(rolloverSessions: rolled, rolloverMonth: newMonth);
}

/// Drop this plan's personal session count and rollover limit. Rolled
/// sessions already granted for the current month stay. Other plans stay.
List<ClientPlanEnrollment> clearPlanOverrides(List<ClientPlanEnrollment> plans, String planId) {
  return [
    for (final e in plans)
      if (e.planId == planId && e.status == "active")
        e.copyWith(clearMaxSessionsOverride: true, clearRolloverMaxOverride: true)
      else
        e,
  ];
}

/// Write this client's numbers onto [planId] only. A plan entry that is not
/// there yet is added, with none of another plan's overrides on it.
List<ClientPlanEnrollment> withPlanAllowance(
  List<ClientPlanEnrollment> plans, {
  required String planId,
  required String today,
  bool touchSessions = false,
  int? maxSessionsOverride,
  String? maxSessionsOverrideMonth,
  bool clearSessions = false,
  bool touchRollover = false,
  int? rolloverMaxOverride,
  bool clearRollover = false,
}) {
  var found = false;
  final next = <ClientPlanEnrollment>[];
  for (final e in plans) {
    if (!found && e.planId == planId && e.status == "active") {
      found = true;
      var updated = e;
      if (touchSessions) {
        updated = updated.copyWith(
          clearMaxSessionsOverride: clearSessions,
          maxSessionsOverride: clearSessions ? null : maxSessionsOverride,
          maxSessionsOverrideMonth: clearSessions ? null : maxSessionsOverrideMonth,
        );
      }
      if (touchRollover) {
        updated = updated.copyWith(
          clearRolloverMaxOverride: clearRollover,
          rolloverMaxOverride: clearRollover ? null : rolloverMaxOverride,
        );
      }
      next.add(updated);
    } else {
      next.add(e);
    }
  }
  final addingSessions = touchSessions && !clearSessions;
  final addingRollover = touchRollover && !clearRollover;
  if (!found && (addingSessions || addingRollover)) {
    next.add(ClientPlanEnrollment(
      planId: planId,
      status: "active",
      startDate: today,
      maxSessionsOverride: addingSessions ? maxSessionsOverride : null,
      maxSessionsOverrideMonth: addingSessions ? maxSessionsOverrideMonth : null,
      rolloverMaxOverride: addingRollover ? rolloverMaxOverride : null,
    ));
  }
  return next;
}
