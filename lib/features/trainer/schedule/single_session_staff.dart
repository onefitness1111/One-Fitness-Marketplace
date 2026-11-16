import "package:flutter/material.dart";
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
}) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text("$clientName has no plan"),
      content: Text(
        "Nothing they hold covers this ${sessionTypeLabel(sessionType)} session. "
        "${priceCents != null ? "Charge them the single-session price to their card on file, or book it free." : "Single sessions are turned off for this type, so you can book it free."} "
        "They need a card on their profile either way.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () => Navigator.pop(ctx, "free"), child: const Text("Book free")),
        if (priceCents != null)
          TextButton(
            onPressed: () => Navigator.pop(ctx, "charge"),
            child: Text("Charge ${_price(priceCents)}", style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w800)),
          ),
      ],
    ),
  );
  if (choice == null) return null;
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
  if (o.full) return "That session filled up${o.refunded ? " — the charge was refunded" : ""}. Nothing was booked.";
  return o.message ?? "Couldn't book that session.";
}
