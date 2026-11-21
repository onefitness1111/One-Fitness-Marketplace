import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/payments/outstanding_balance.dart";
import "../../../core/utils/late_fee_notice.dart";
import "../../../core/payments/payment_sheet_service.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/dashboard_extras.dart";
import "../../../data/providers/platform_settings_provider.dart";

/// True when booking must stop. The sheet is the notice, with Pay now.
Future<bool> stopForOutstandingBalance(BuildContext context, String clientId) async {
  final cents = await unpaidBalanceCents(clientId);
  if (cents == null || !context.mounted) return cents != null;
  await showOutstandingBalanceSheet(context, balanceCents: cents);
  return true;
}

/// Shown every time a client tries to book while they owe a fee.
Future<void> showOutstandingBalanceSheet(BuildContext context, {required int balanceCents}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => _BalanceDueSheet(balanceCents: balanceCents),
  );
}

class _BalanceDueSheet extends ConsumerStatefulWidget {
  const _BalanceDueSheet({required this.balanceCents});

  final int balanceCents;

  @override
  ConsumerState<_BalanceDueSheet> createState() => _BalanceDueSheetState();
}

class _BalanceDueSheetState extends ConsumerState<_BalanceDueSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _pay() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await PaymentSheetService.payBalance(
      businessName: ref.read(platformSettingsProvider).businessName,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.cancelled) return;
    if (!result.ok) {
      setState(() => _error = result.error ?? "The payment didn't go through.");
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("Outstanding balance", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              outstandingBalanceMessage(widget.balanceCents),
              style: TextStyle(fontSize: 13.5, color: AppColors.txt, height: 1.4),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(fontSize: 12.5, color: AppColors.txt)),
            ],
            const SizedBox(height: 14),
            BtnGold(full: true, onPressed: _busy ? null : _pay, child: Text(_busy ? "Paying…" : "Pay now")),
            const SizedBox(height: 8),
            BtnGhost(full: true, onPressed: _busy ? null : () => Navigator.pop(context), child: const Text("Not now")),
          ],
        ),
      ),
    );
  }
}

/// The same notice on the client's home screen, with the same Pay now button.
class BalanceDueBanner extends ConsumerWidget {
  const BalanceDueBanner({super.key, required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cents = ref.watch(dashboardExtrasProvider).balanceCents;
    if (cents == null || cents >= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(outstandingBalanceMessage(cents), style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            BtnGold(
              onPressed: () async {
                await showOutstandingBalanceSheet(context, balanceCents: cents);
                try {
                  final fresh = await SupabaseService.loadBalanceCents(clientId);
                  ref.read(dashboardExtrasProvider.notifier).replace(
                        ref.read(dashboardExtrasProvider).copyWith(
                              balanceCents: fresh < 0 ? fresh : null,
                              clearBalance: fresh >= 0,
                            ),
                      );
                } catch (_) {}
              },
              child: const Text("Pay now"),
            ),
          ],
        ),
      ),
    );
  }
}
