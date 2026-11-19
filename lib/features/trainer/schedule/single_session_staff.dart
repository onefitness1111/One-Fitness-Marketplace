import "package:flutter/material.dart";
import "../../../core/payments/outstanding_balance.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../data/models/single_session_credit.dart";

String _price(int cents) => cents % 100 == 0 ? "\$${cents ~/ 100}" : "\$${(cents / 100).toStringAsFixed(2)}";

/// A coach or owner is booking a client who holds nothing that covers this
/// session. They choose to charge the single-session price to the client's card
/// on file, or to book it free. Either way the client needs a card on their
/// profile (so a late cancellation or no-show fee can still be collected), and
/// the server enforces that and the price.
///
/// Returns null when staff backed out. Otherwise the server's outcome, with
/// [SingleSessionOutcome.booked] telling whether the session now exists.
Future<SingleSessionOutcome?> bookClientWithoutPlan({
  required BuildContext context,
  required String clientName,
  required String clientId,
  required String sessionType,
  required String trainerId,
  required String date,
  required int slot,
  required String discipline,
  String? locationName,
  required int? priceCents, // null = single sessions are off for this type
  required bool isOwner,
}) async {
  var account = 0;
  try {
    account = await SupabaseService.loadBalanceCents(clientId);
  } catch (_) {}
  final bill = priceCents == null ? null : singleSessionBill(sessionCents: priceCents, accountBalanceCents: account);
  var used = 0;
  if (!isOwner) {
    try {
      used = await SupabaseService.coachFreeAddsUsed();
    } catch (_) {
      used = 0;
    }
  }
  final needsApproval = !isOwner && used >= 1;
  final chargeLine = bill != null && bill.includesBalance
      ? "${bill.breakdown}. Charged to the card on file, or book it free."
      : priceCents != null
          ? "Charge them the single-session price to their card on file, or book it free."
          : "Single sessions are turned off for this type, so you can book it free.";
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text("$clientName has no plan"),
      content: Text(
        "Nothing they hold covers this ${sessionTypeLabel(sessionType)} session. "
        "$chargeLine "
        "${needsApproval ? "The one free add for this week is already used, so another free add waits for the owner." : "A free add does not count toward coach pay."} "
        "They need a card on their profile either way.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () => Navigator.pop(ctx, "free"), child: Text(needsApproval ? "Ask the owner" : "Book free")),
        if (priceCents != null)
          TextButton(
            onPressed: () => Navigator.pop(ctx, "charge"),
            child: Text(
              "Charge ${_price(bill?.totalCents ?? priceCents)}",
              style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w800),
            ),
          ),
      ],
    ),
  );
  if (choice == null) return null;
  if (choice == "free" && needsApproval) {
    try {
      await SupabaseService.submitCoachRequest(
        kind: "extra_free_session",
        clientId: clientId,
        reason: "Extra free session this week",
        payload: {
          "clientId": clientId,
          "trainerId": trainerId,
          "date": date,
          "slot": slot,
          "sessionType": sessionType,
          "discipline": discipline,
          "locationName": locationName ?? "",
        },
      );
      return const SingleSessionOutcome(
        status: "requested",
        message: "Sent to the owner. Nothing is booked until they approve it.",
      );
    } catch (e) {
      return SingleSessionOutcome(status: "error", message: e.toString().replaceFirst("Exception: ", ""));
    }
  }
  try {
    return await SupabaseService.staffSingleSession(
      clientId: clientId,
      charge: choice == "charge",
      sessionType: sessionType,
      trainerId: trainerId,
      date: date,
      slot: slot,
      discipline: discipline,
      locationName: locationName,
    );
  } catch (e) {
    return SingleSessionOutcome(status: "error", message: e.toString().replaceFirst("Exception: ", ""));
  }
}

/// A one-line explanation for an outcome that did not end in a booking.
String singleSessionFailureMessage(SingleSessionOutcome o) {
  if (o.full && o.refunded && (o.message ?? "").trim().isNotEmpty) return o.message!.trim();
  if (o.full) return "That session filled up${o.refunded ? " — the charge was refunded" : ""}. Nothing was booked.";
  return o.message ?? "Couldn't book that session.";
}

/// The on-screen notice when a card was charged and then refunded because
/// the session filled. Not a generic error.
Future<void> showFilledRefundDialog(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text("Session filled"),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK")),
      ],
    ),
  );
}
