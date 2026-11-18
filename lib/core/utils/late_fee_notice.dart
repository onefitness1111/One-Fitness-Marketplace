import "../payments/outstanding_balance.dart";
import "../supabase/supabase_service.dart";

/// Takes the late-cancellation fee for a booking that is about to be
/// cancelled. Must run BEFORE the booking is deleted (the server works the fee
/// out from it). Never throws: a failure here must not stop the cancellation.
Future<Map<String, dynamic>?> takeLateCancelFee(String bookingId) async {
  try {
    return await SupabaseService.chargeLateCancellation(bookingId: bookingId);
  } catch (_) {
    return null;
  }
}

/// What the client is told when a coach marks attendance that can cost money.
String attendanceMarkedNotice({
  required String coachName,
  required String status,
  required int cents,
  bool onBalance = false,
}) {
  final amount = "\$${(cents / 100).toStringAsFixed(2)}";
  if (onBalance && cents > 0) {
    return "$coachName marked this session. You have an outstanding balance of $amount. Please pay your balance to book sessions.";
  }
  if (status == "no-show") {
    return "$coachName marked this session as a no-show. A $amount fee was charged and this session was used.";
  }
  if (status == "late-cancel") {
    if (cents <= 0) return "$coachName marked this session as a late cancel. The session goes back on your plan.";
    return "$coachName marked this session as a late cancel. A $amount fee was charged. The session goes back on your plan.";
  }
  if (status == "early-cancel") {
    return "$coachName marked this session as an early cancel. There's no fee, and the session goes back on your plan.";
  }
  return "$coachName updated this session.";
}

/// What to tell the client after a late cancellation, or null for nothing.
String? lateFeeNotice(Map<String, dynamic>? res) {
  if (res == null || res["alreadyCharged"] == true) return null;
  final cents = (res["feeCents"] as num?)?.toInt() ?? 0;
  if (cents <= 0) return null;
  final amount = "\$${(cents / 100).toStringAsFixed(2)}";
  final close = res["kind"] == "close";
  final what = close ? "$amount fee (cancelled within 4 hours)" : "$amount late-cancellation fee";
  if (res["charged"] == true) {
    return "$what charged. Your session is back on your plan.";
  }
  return "Cancelled. ${outstandingBalanceMessage(cents)} Your session is back on your plan.";
}

/// Null when the client may book. The database enforces the same rule.
Future<int?> unpaidBalanceCents(String clientId) async {
  try {
    final cents = await SupabaseService.loadBalanceCents(clientId);
    if (cents < 0) return cents;
  } catch (_) {
    // Offline: the database re-checks when the booking is saved.
  }
  return null;
}

/// Null when the client may book; otherwise the sentence they are shown.
Future<String?> bookingBlockMessage(String clientId) async {
  final cents = await unpaidBalanceCents(clientId);
  if (cents == null) return null;
  return outstandingBalanceMessage(cents);
}
