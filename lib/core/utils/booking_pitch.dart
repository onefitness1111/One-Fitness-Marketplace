import "../../data/models/membership_plan.dart";

/// The sentence under Confirm booking. It names the plan the session comes
/// from, and it matches the cancel rules: a booking does not use a session,
/// a cancel gives it back, and the fees are money only.
String bookingConfirmPitch({
  required String sessionLabel,
  required int cap,
  required String coverage,
}) {
  final room = cap <= 1
      ? "$sessionLabel is just you and your coach."
      : "$sessionLabel is shared by up to $cap people.";
  return "$coverage $room "
      "Booking holds the spot. The session is used when you check in or your coach marks a no-show. "
      "Cancelling gives it back. Cancelling within 12 hours is a \$15 fee. "
      "Cancelling within 4 hours is a \$25 fee. Neither fee uses up the session.";
}

/// Large group is part of a membership. A package covers it only when that
/// package says so. The old line said every plan included it.
bool planCoversLargeGroup(MembershipPlan plan) =>
    plan.kind == PlanKind.membership || plan.allowedTypes.contains("large-group");

String largeGroupBlurb(List<MembershipPlan> plans, {required int cap}) {
  final names = [
    for (final p in plans)
      if (planCoversLargeGroup(p)) p.name,
  ];
  final size = "Hike and Outdoor HIIT — 1 hour, up to $cap people.";
  if (names.isEmpty) return size;
  if (names.length == 1) return "$size Covered by ${names.first}.";
  return "$size Covered by ${names.join(" and ")}.";
}
