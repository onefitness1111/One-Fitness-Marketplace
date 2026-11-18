import "package:flutter/material.dart";
import "../../../core/payments/client_charge.dart";
import "../../../core/payments/outstanding_balance.dart";
import "../../../core/payments/payment_sheet_service.dart";
import "../../../data/providers/platform_settings_provider.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// Charges the fee on the card Stripe already has. Coaches see the brand
/// and last four digits, not the billing address.
class ChargeClientSection extends ConsumerStatefulWidget {
  const ChargeClientSection({super.key, required this.clientId, required this.onClose});

  final String clientId;
  final VoidCallback onClose;

  @override
  ConsumerState<ChargeClientSection> createState() => _ChargeClientSectionState();
}

class _ChargeClientSectionState extends ConsumerState<ChargeClientSection> {
  String _kind = "late";
  bool _busy = false;
  bool _confirming = false;
  String? _error;
  String? _done;
  String? _ledgerId;
  Map<String, dynamic>? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preview = await SupabaseService.chargeClient(clientId: widget.clientId, action: "preview");
      if (mounted) setState(() => _preview = preview);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't look up the card.");
    }
  }

  Future<void> _charge() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await SupabaseService.chargeClient(
        clientId: widget.clientId,
        action: "charge",
        kind: _kind,
        ledgerId: _ledgerId,
      );
      if (result["charged"] == true) {
        final card = result["card"];
        final last4 = card is Map ? card["last4"] : "";
        setState(() {
          _done = "Charged ${feeLabelFor(_kind)} on the card ending $last4. The client was notified.";
          _ledgerId = null;
        });
        return;
      }
      if (result["balanceRecorded"] == true) {
        final cents = (result["balanceCents"] as num?)?.toInt();
        final shown = cents == null ? formatSignedMoney(-feeCentsFor(_kind)) : formatSignedMoney(cents);
        setState(() {
          _ledgerId = result["ledgerId"]?.toString();
          _done = "Recorded as a balance of $shown. The client was notified. Adding a card is optional.";
        });
      }
    } catch (_) {
      setState(() => _error = "The charge didn't go through.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addCard() async {
    final business = ref.read(platformSettingsProvider).businessName;
    final saved = await PaymentSheetService.saveCardForCharge(
      clientId: widget.clientId,
      businessName: business,
    );
    if (!mounted) return;
    if (!saved.ok) {
      setState(() => _error = saved.cancelled ? null : (saved.error ?? "Couldn't save that card."));
      return;
    }
    await _charge();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final card = preview?["card"];
    final brand = card is Map ? card["brand"]?.toString() ?? "Card" : "";
    final last4 = card is Map ? card["last4"]?.toString() ?? "" : "";
    final cardLine = preview == null
        ? "Looking up the card…"
        : preview["hasCard"] == true
            ? "$brand •••• $last4"
            : "No card on file";
    final cents = _kind == "late" ? lateFeeCents : shortNoticeFeeCents;
    if (_done != null) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_done!, style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: AppColors.txt, fontSize: 13)),
            ],
            if (_ledgerId != null) ...[
              const SizedBox(height: 12),
              BtnGold(onPressed: _busy ? null : _addCard, child: Text(_busy ? "Charging…" : "Add a card and charge")),
            ],
            const SizedBox(height: 12),
            BtnGhost(onPressed: widget.onClose, child: Text(_ledgerId == null ? "Back" : "Skip")),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text("Charge card", style: TextStyle(color: AppColors.txt, fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(cardLine, style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _FeeChoice(label: "Late cancellation — \$15", selected: _kind == "late", onTap: () => setState(() => _kind = "late")),
        _FeeChoice(label: "Short notice or no-show — \$25", selected: _kind != "late", onTap: () => setState(() => _kind = "close")),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: AppColors.txt, fontSize: 13)),
        ],
        const SizedBox(height: 12),
        if (!_confirming)
          BtnGold(onPressed: preview == null ? null : () => setState(() => _confirming = true), child: const Text("Review"))
        else ...[
          Text(
            "Charge \$${(cents / 100).toStringAsFixed(2)} on $cardLine.",
            style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          BtnGold(onPressed: _busy ? null : _charge, child: Text(_busy ? "Charging…" : "Charge")),
          const SizedBox(height: 8),
          BtnGhost(onPressed: () => setState(() => _confirming = false), child: const Text("Back")),
        ],
      ],
    );
  }
}

class _FeeChoice extends StatelessWidget {
  const _FeeChoice({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TapHighlight(
        selected: selected,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold : AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? AppColors.gold : AppColors.line),
          ),
          child: Text(label, style: TextStyle(color: selected ? AppColors.onGold : AppColors.txt, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
