import "package:flutter/material.dart";
import "../../../core/payments/outstanding_balance.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";

/// True when staff may continue adding this client.
///
/// A negative balance always shows "This client has an outstanding balance
/// of $X." The owner can continue any number of times. A coach can continue
/// once. After that one, the coach is stopped until the balance is paid or
/// the owner waives it.
Future<bool> confirmStaffBalanceAdd(
  BuildContext context, {
  required String clientId,
  required bool isOwner,
}) async {
  final hold = await SupabaseService.loadBookingHold(clientId);
  final gate = BalanceGate(balanceCents: hold.balanceCents, graceUsed: hold.graceUsed);
  final decision = staffAddDecision(isOwner: isOwner, gate: gate);
  if (decision == StaffAdd.clear) return true;
  if (!context.mounted) return false;
  final warning = staffBalanceWarning(gate.balanceCents);
  if (decision == StaffAdd.blocked) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Outstanding balance"),
        content: Text(
          "$warning You already added them to one session while this is unpaid. "
          "Further bookings wait until they pay or the owner waives it.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK")),
        ],
      ),
    );
    return false;
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text("Outstanding balance"),
      content: Text(
        isOwner
            ? "$warning You can still add them to a session, or waive the balance from their profile."
            : "$warning You can add them to one session while this is unpaid.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(isOwner ? "Add anyway" : "Add this session"),
        ),
      ],
    ),
  );
  return go == true;
}

/// Pulls the warning sentence out of a server refusal.
String staffBalanceWarningFromError(String text) {
  final start = text.indexOf("This client has an outstanding balance");
  if (start < 0) return "This client has an outstanding balance.";
  final end = text.indexOf(".", start);
  if (end < 0) return text.substring(start);
  return text.substring(start, end + 1);
}
