import "package:flutter/material.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_info.dart";
import "../../../data/models/client_plan.dart";
import "../../../data/models/membership_plan.dart";

/// Owner-only: this client's own price for [plan]. Leaves the plan's list
/// price untouched; "Reset" goes back to it.
class PlanPriceRow extends StatefulWidget {
  const PlanPriceRow({super.key, required this.info, required this.plan, required this.onChanged});
  final ClientInfo info;
  final MembershipPlan plan;
  final void Function(List<ClientPlanEnrollment> plans) onChanged;

  @override
  State<PlanPriceRow> createState() => _PlanPriceRowState();
}

class _PlanPriceRowState extends State<PlanPriceRow> {
  bool _busy = false;

  ClientPlanEnrollment? get _enrolment {
    for (final e in widget.info.plans) {
      if (e.planId == widget.plan.id && e.status == "active") return e;
    }
    return null;
  }

  static String _money(int cents) => "\$${(cents / 100).toStringAsFixed(2)}";

  Future<void> _save(int? cents) async {
    final existing = _enrolment;
    if (existing == null) return;
    setState(() => _busy = true);
    try {
      final next = [
        for (final e in widget.info.plans)
          if (identical(e, existing)) e.copyWith(priceCents: cents, clearPrice: cents == null) else e,
      ];
      await SupabaseService.updateClientPlans(widget.info.id, next);
      widget.onChanged(next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(cents == null ? "Back to the plan price." : "Price set to ${_money(cents)}.")),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save the price — try again.")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final current = _enrolment?.priceCents ?? widget.plan.priceCents;
    final ctrl = TextEditingController(text: (current / 100).toStringAsFixed(2));
    final cents = await showKeyboardSheet<int>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text("Price for this client", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(prefixText: "\$ "),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: BtnGhost(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel"))),
              const SizedBox(width: 8),
              Expanded(
                child: BtnGold(
                  onPressed: () {
                    final v = double.tryParse(ctrl.text.replaceAll(RegExp(r"[^0-9.]"), ""));
                    if (v == null || v < 0) return;
                    Navigator.pop(ctx, (v * 100).round());
                  },
                  child: const Text("Save"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (cents != null) await _save(cents);
  }

  @override
  Widget build(BuildContext context) {
    final custom = _enrolment?.priceCents;
    final shown = custom ?? widget.plan.priceCents;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("PRICE FOR THIS CLIENT", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
              const SizedBox(height: 2),
              Text(
                custom == null ? "${_money(shown)} (plan price)" : "${_money(shown)} (custom)",
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        if (custom != null) TextButton(onPressed: _busy ? null : () => _save(null), child: const Text("Reset")),
        TextButton(onPressed: _busy ? null : _edit, child: const Text("Change")),
      ],
    );
  }
}
