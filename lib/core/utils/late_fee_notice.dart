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

/// What to tell the client after a late cancellation, or null for nothing.
String? lateFeeNotice(Map<String, dynamic>? res) {
  if (res == null || res["alreadyCharged"] == true) return null;
  final cents = (res["feeCents"] as num?)?.toInt() ?? 0;
  if (cents <= 0) return null;
  final amount = "\$${(cents / 100).toStringAsFixed(2)}";
  if (res["charged"] == true) return "$amount charged for the late cancellation.";
  return "Cancelled. We couldn't charge the $amount late cancellation fee, so it's been added to your balance. "
      "You'll need to pay it before booking again.";
}

/// Null when the client may book; otherwise why not. A client who owes money
/// (a late-cancel or no-show fee that couldn't be collected) can't book any
/// future session until it is paid. The database enforces the same rule.
Future<String?> bookingBlockMessage(String clientId) async {
  try {
    final cents = await SupabaseService.loadBalanceCents(clientId);
    if (cents < 0) {
      return "You have an unpaid balance of \$${(-cents / 100).toStringAsFixed(2)}. "
          "Please pay it from your Profile before booking another session.";
    }
  } catch (_) {
    // Offline: the database re-checks when the booking is saved.
  }
  return null;
}
