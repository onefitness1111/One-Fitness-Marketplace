import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../core/payments/payment_sheet_service.dart";
import "../../core/supabase/supabase_service.dart";
import "../../core/theme/app_colors.dart";
import "../../core/widgets/widgets.dart";
import "../../data/providers/platform_settings_provider.dart";

String money(int cents) => "\$${(cents.abs() / 100).toStringAsFixed(2)}";

/// A client's account balance. Negative = they owe the gym (an uncollected
/// late-cancel / no-show fee), positive = credit.
///
/// [editable] (coach / owner): shows an Edit button to set it to any amount.
/// Otherwise (the client's own profile): shows a Pay balance button while they
/// owe, which opens the card sheet and lifts the booking block once paid.
class BalanceCard extends ConsumerStatefulWidget {
  const BalanceCard({super.key, required this.clientId, this.editable = false});

  final String clientId;
  final bool editable;

  @override
  ConsumerState<BalanceCard> createState() => _BalanceCardState();
}

class _BalanceCardState extends ConsumerState<BalanceCard> {
  int? _cents;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await SupabaseService.loadBalanceCents(widget.clientId);
      if (mounted) setState(() => _cents = c);
    } catch (_) {}
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pay() async {
    setState(() => _busy = true);
    final result = await PaymentSheetService.payBalance(
      businessName: ref.read(platformSettingsProvider).businessName,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.error != null) {
      _toast(result.error!);
    } else if (!result.cancelled) {
      _toast("Payment received — your balance will update in a moment.");
      // The webhook credits the balance; give it a moment, then re-read.
      await Future<void>.delayed(const Duration(seconds: 3));
      await _load();
    }
  }

  Future<void> _edit() async {
    final current = _cents ?? 0;
    final amount = TextEditingController(text: (current.abs() / 100).toStringAsFixed(2));
    var owes = current < 0;
    final saved = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: AppColors.card,
          title: const Text("Edit balance", style: TextStyle(fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text("Owes"),
                      selected: owes,
                      onSelected: (_) => setD(() => owes = true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text("Credit"),
                      selected: !owes,
                      onSelected: (_) => setD(() => owes = false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(prefixText: "\$ ", labelText: "Amount"),
              ),
              const SizedBox(height: 8),
              Text(
                owes ? "A client who owes can't book until it is paid." : "Credit is shown on their profile.",
                style: TextStyle(fontSize: 11.5, color: AppColors.mute),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            TextButton(
              onPressed: () {
                final v = double.tryParse(amount.text.trim());
                if (v == null || v < 0) return;
                final cents = (v * 100).round();
                Navigator.pop(ctx, owes ? -cents : cents);
              },
              child: const Text("Save", style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
    amount.dispose();
    if (saved == null) return;
    try {
      final v = await SupabaseService.setClientBalance(widget.clientId, saved);
      if (mounted) setState(() => _cents = v);
    } catch (e) {
      _toast("Couldn't change the balance — try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final cents = _cents;
    final owes = (cents ?? 0) < 0;
    final color = cents == null || cents == 0 ? AppColors.mute : (owes ? AppColors.danger : AppColors.grn);
    final label = cents == null
        ? "…"
        : cents == 0
            ? "\$0.00"
            : owes
                ? "${money(cents)} owed"
                : "${money(cents)} credit";
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          children: [
            Icon(LucideIcons.wallet, size: 17, color: AppColors.gold),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("ACCOUNT BALANCE", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
                  Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
                  if (owes && !widget.editable)
                    Text(
                      "Pay this to book sessions again.",
                      style: TextStyle(fontSize: 11.5, color: AppColors.mute),
                    ),
                ],
              ),
            ),
            if (widget.editable)
              TextButton(onPressed: cents == null ? null : _edit, child: const Text("Edit"))
            else if (owes)
              FilledButton(onPressed: _busy ? null : _pay, child: Text(_busy ? "…" : "Pay balance")),
          ],
        ),
      ),
    );
  }
}
