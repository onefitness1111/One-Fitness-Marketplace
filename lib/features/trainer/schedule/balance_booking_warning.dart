import "package:flutter/material.dart";
import "../../../core/payments/outstanding_balance.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";

/// True when staff may continue adding this client.
///
/// A negative balance always shows the outstanding-balance dialog. Charging
/// the card on file has to succeed before the session is booked. Booking
/// anyway is the one grace booking, and only while that grace is still open
/// for a coach. The owner can always book anyway.
Future<bool> confirmStaffBalanceAdd(
  BuildContext context, {
  required String clientId,
  required bool isOwner,
  Future<String?> Function(String clientId)? chargeBalance,
}) async {
  final hold = await SupabaseService.loadBookingHold(clientId);
  final gate = BalanceGate(balanceCents: hold.balanceCents, graceUsed: hold.graceUsed);
  final decision = staffAddDecision(isOwner: isOwner, gate: gate);
  if (decision == StaffAdd.clear) return true;
  if (!context.mounted) return false;
  final choices = staffBalanceChoices(isOwner: isOwner, gate: gate);
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StaffBalanceDialog(
      warning: staffBalanceWarning(gate.balanceCents),
      bookAnywayEnabled: choices.bookAnywayEnabled,
      blockedNote: choices.note,
      onCharge: () => (chargeBalance ?? SupabaseService.chargeOutstandingOnFile)(clientId),
    ),
  );
  return go == true;
}

/// The outstanding-balance choice. Buttons are stacked, full width, in a
/// fixed order: charge, book anyway, cancel.
class StaffBalanceDialog extends StatefulWidget {
  const StaffBalanceDialog({
    super.key,
    required this.warning,
    required this.bookAnywayEnabled,
    required this.onCharge,
    this.blockedNote,
  });

  final String warning;
  final bool bookAnywayEnabled;
  final String? blockedNote;
  final Future<String?> Function() onCharge;

  @override
  State<StaffBalanceDialog> createState() => _StaffBalanceDialogState();
}

class _StaffBalanceDialogState extends State<StaffBalanceDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _charge() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onCharge();
    } catch (_) {
      error = "The card on file was declined. Nothing was booked.";
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text("Outstanding balance", textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "${widget.warning} You can add them to one session while this is unpaid. "
            "The charge uses the card on file.",
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.txt, fontWeight: FontWeight.w700),
            ),
          ],
          const SizedBox(height: 18),
          _BalanceButton(
            key: const Key("charge-balance-book"),
            label: "Charge balance & book",
            filled: true,
            busy: _busy,
            onPressed: _busy ? null : _charge,
          ),
          const SizedBox(height: 10),
          _BalanceButton(
            key: const Key("book-anyway"),
            label: "Book session anyway",
            filled: false,
            onPressed: _busy || !widget.bookAnywayEnabled ? null : () => Navigator.pop(context, true),
          ),
          if (widget.blockedNote != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.blockedNote!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.mute),
            ),
          ],
          const SizedBox(height: 10),
          TextButton(
            key: const Key("balance-cancel"),
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
        ],
      ),
    );
  }
}

class _BalanceButton extends StatelessWidget {
  const _BalanceButton({
    super.key,
    required this.label,
    required this.filled,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final bool filled;
  final VoidCallback? onPressed;
  final bool busy;

  static const _radius = 12.0;
  static const _height = 48.0;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius));
    final child = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
          )
        : Text(label, textAlign: TextAlign.center);
    if (filled) {
      return SizedBox(
        height: _height,
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white,
            disabledForegroundColor: Colors.black,
            elevation: 0,
            shape: shape,
          ),
          child: child,
        ),
      );
    }
    return SizedBox(
      height: _height,
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.txt,
          disabledForegroundColor: AppColors.mute,
          side: BorderSide(color: onPressed == null ? AppColors.line : AppColors.mute),
          shape: shape,
        ),
        child: child,
      ),
    );
  }
}

/// Pulls the warning sentence out of a server refusal.
String staffBalanceWarningFromError(String text) {
  final start = text.indexOf("This client has an outstanding balance");
  if (start < 0) return "This client has an outstanding balance.";
  final end = text.indexOf(".", start);
  if (end < 0) return text.substring(start);
  return text.substring(start, end + 1);
}
