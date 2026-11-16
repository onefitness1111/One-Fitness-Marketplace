import "package:flutter/material.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_info.dart";

/// Owner-only: what this client's membership is set to renew at versus what
/// it will actually renew at, with overrides for the renewal price, the next
/// renewal date and the expiration date.
class RenewalTermsSection extends StatefulWidget {
  const RenewalTermsSection({super.key, required this.info, required this.onBack});
  final ClientInfo info;
  final VoidCallback onBack;

  @override
  State<RenewalTermsSection> createState() => _RenewalTermsSectionState();
}

class _RenewalTermsSectionState extends State<RenewalTermsSection> {
  Map<String, dynamic>? _terms;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  final _price = TextEditingController();
  String? _renewalDate;
  String? _endsOn;
  bool _clearEnd = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  String _money(num? cents) => cents == null ? "—" : "\$${(cents / 100).toStringAsFixed(2)}";

  void _apply(Map<String, dynamic> t) {
    _terms = t;
    final rp = t["renewalPriceCents"] as num?;
    _price.text = rp == null ? "" : (rp / 100).toStringAsFixed(2);
    _renewalDate = null;
    _endsOn = null;
    _clearEnd = false;
  }

  Future<void> _load() async {
    try {
      final t = await SupabaseService.ownerSubscriptionTerms(clientId: widget.info.id);
      if (mounted) setState(() => _apply(t));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _pickDate(String? initial) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(initial ?? "") ?? now.add(const Duration(days: 1)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: DateTime(now.year + 10),
    );
    if (d == null) return null;
    return "${d.year.toString().padLeft(4, "0")}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";
  }

  Future<void> _save() async {
    final t = _terms;
    if (t == null) return;
    final typed = double.tryParse(_price.text.trim());
    final currentCents = (t["renewalPriceCents"] as num?)?.round();
    final newCents = typed == null ? null : (typed * 100).round();
    final priceChanged = newCents != null && newCents != currentCents;
    if (!priceChanged && _renewalDate == null && _endsOn == null && !_clearEnd) {
      setState(() => _error = "Nothing to save — change the price or a date first.");
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final next = await SupabaseService.ownerSubscriptionTerms(
        clientId: widget.info.id,
        action: "update",
        renewalPriceCents: priceChanged ? newCents : null,
        renewalDate: _renewalDate,
        endsOn: _endsOn,
        clearEnd: _clearEnd,
      );
      if (!mounted) return;
      setState(() => _apply(next));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Renewal terms updated.")));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: AppColors.mute))),
            Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = _terms;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: widget.onBack, title: "Profile"),
          const SizedBox(height: 10),
          SectionLabel("Renewal — ${widget.info.name}"),
          const SizedBox(height: 8),
          if (_loading)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: AppColors.gold)))
          else if (t == null)
            HintBox(text: _error ?? "Couldn't load the renewal details.")
          else if (t["hasSubscription"] != true)
            const HintBox(text: "This membership isn't billed through a subscription, so there is no renewal price or date to change.")
          else ...[
            AppCard(
              child: Column(
                children: [
                  _row("Plan price", "${_money(t["planPriceCents"] as num?)}/${t["interval"] ?? "month"}"),
                  _row("Renews at", "${_money(t["renewalPriceCents"] as num?)}/${t["interval"] ?? "month"}"),
                  _row("Next renewal", (t["nextRenewalDate"] as String?) ?? "—"),
                  _row("Expires", (t["endsOn"] as String?) ?? "Doesn't expire"),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text("RENEWAL PRICE (\$)", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
            const SizedBox(height: 6),
            TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), prefixText: "\$ "),
            ),
            const SizedBox(height: 4),
            Text(
              "Applies from the next renewal. Nothing is charged or refunded now.",
              style: TextStyle(fontSize: 11, color: AppColors.mute),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: () async {
                final d = await _pickDate(_renewalDate);
                if (d != null && mounted) setState(() => _renewalDate = d);
              },
              child: Text(_renewalDate == null ? "Change next renewal date" : "Next renewal: $_renewalDate"),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                final d = await _pickDate(_endsOn);
                if (d != null && mounted) {
                  setState(() {
                    _endsOn = d;
                    _clearEnd = false;
                  });
                }
              },
              child: Text(_endsOn == null ? "Set expiration date" : "Expires: $_endsOn"),
            ),
            if (t["endsOn"] != null)
              TextButton(
                onPressed: () => setState(() {
                  _clearEnd = !_clearEnd;
                  _endsOn = null;
                }),
                child: Text(_clearEnd ? "Keep the current expiration" : "Remove expiration date"),
              ),
            const SizedBox(height: 4),
            Text(
              "Moving the renewal date skips billing until that day, with no proration.",
              style: TextStyle(fontSize: 11, color: AppColors.mute),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
              ),
            const SizedBox(height: 14),
            BtnGold(full: true, onPressed: _saving ? null : _save, child: Text(_saving ? "Saving…" : "Save changes")),
          ],
        ],
      ),
    );
  }
}
