import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/payments_to_collect.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_info.dart";
import "../../../data/providers/client_balances_provider.dart";
import "../../../data/providers/trainer_providers.dart";

/// Rows for the Balances tab. Tests and screenshots seed this and pass
/// [CollectPaymentsScreen.load] as a no-op so the screen does not call
/// the network.
class BalanceDuesNotifier extends Notifier<List<BalanceDue>> {
  @override
  List<BalanceDue> build() => const [];

  void setAll(List<BalanceDue> next) => state = next;

  void remove(String clientId) => state = [for (final row in state) if (row.clientId != clientId) row];
}

final balanceDuesProvider = NotifierProvider<BalanceDuesNotifier, List<BalanceDue>>(BalanceDuesNotifier.new);

/// Owner-only list of money still to collect.
///
/// Unsuccessful / Declined stays empty: a declined card is not stored as
/// its own charge. The fee is added to the client's balance, which is the
/// Balances tab.
class CollectPaymentsScreen extends ConsumerStatefulWidget {
  const CollectPaymentsScreen({super.key, this.load, this.chargeBalance, this.waiveBalance});

  /// When set, the screen does not fetch. Used by tests and screenshots
  /// that already seeded [balanceDuesProvider].
  final Future<void> Function()? load;

  /// Defaults to charging each unpaid fee on the saved card.
  final Future<String?> Function(String clientId)? chargeBalance;

  /// Defaults to the owner-only waive of the whole negative balance.
  final Future<int> Function(String clientId)? waiveBalance;

  @override
  ConsumerState<CollectPaymentsScreen> createState() => _CollectPaymentsScreenState();
}

class _CollectPaymentsScreenState extends ConsumerState<CollectPaymentsScreen> {
  int _tab = 0;
  bool _loading = false;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    final custom = widget.load;
    if (custom != null) {
      custom();
    } else {
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final roster = ref.read(trainerRosterProvider);
    try {
      final rows = await loadBalancesDue(roster);
      if (!mounted) return;
      final balances = {for (final client in roster) client.id: 0};
      for (final row in rows) {
        balances[row.clientId] = row.balanceCents;
      }
      ref.read(clientBalancesProvider.notifier).replace(balances);
      ref.read(balanceDuesProvider.notifier).setAll(rows);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't load balances.")));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _charge(BalanceDue row) async {
    final ok = await _confirm(
      title: "Charge card",
      message: "Charge ${row.name}'s saved card ${moneyFromCents(row.owedCents)}?",
      confirm: "Charge card",
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = row.clientId);
    try {
      final charge = widget.chargeBalance ?? SupabaseService.chargeOutstandingOnFile;
      final error = await charge(row.clientId);
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
        return;
      }
      _settled(row.clientId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("The charge didn't go through.")));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _waive(BalanceDue row) async {
    final ok = await _confirm(
      title: "Waive balance",
      message: "Waive ${row.name}'s ${moneyFromCents(row.owedCents)} balance? This clears what they owe without charging a card.",
      confirm: "Waive",
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = row.clientId);
    try {
      final waive = widget.waiveBalance ?? SupabaseService.waiveClientBalance;
      await waive(row.clientId);
      if (!mounted) return;
      _settled(row.clientId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't waive that balance.")));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  void _settled(String clientId) {
    final balances = Map<String, int>.from(ref.read(clientBalancesProvider));
    balances[clientId] = 0;
    ref.read(clientBalancesProvider.notifier).replace(balances);
    ref.read(balanceDuesProvider.notifier).remove(clientId);
  }

  Future<bool> _confirm({required String title, required String message, required String confirm}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(title, style: TextStyle(color: AppColors.txt, fontSize: 16, fontWeight: FontWeight.w800)),
        content: Text(message, style: TextStyle(color: AppColors.txt, fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text("Cancel", style: TextStyle(color: AppColors.mute))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirm, style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final dues = ref.watch(balanceDuesProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        Text("Collect Payments", style: TextStyle(color: AppColors.txt, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        SegmentedToggle(
          labels: const ["Unsuccessful / Declined", "Balances"],
          index: _tab,
          fontSize: 11,
          onChanged: (i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 16),
        if (_tab == 0) const _DeclinedEmpty() else _Balances(loading: _loading, rows: dues, busyId: _busyId, onCharge: _charge, onWaive: _waive),
      ],
    );
  }
}

class _DeclinedEmpty extends StatelessWidget {
  const _DeclinedEmpty();

  @override
  Widget build(BuildContext context) {
    return const HintBox(
      text: "Declined charges aren't kept as their own list. When a card is declined, the fee is added to the client's balance. Open Balances to collect it.",
    );
  }
}

class _Balances extends StatelessWidget {
  const _Balances({
    required this.loading,
    required this.rows,
    required this.busyId,
    required this.onCharge,
    required this.onWaive,
  });

  final bool loading;
  final List<BalanceDue> rows;
  final String? busyId;
  final Future<void> Function(BalanceDue) onCharge;
  final Future<void> Function(BalanceDue) onWaive;

  @override
  Widget build(BuildContext context) {
    if (loading && rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(color: AppColors.gold)),
      );
    }
    if (rows.isEmpty) return const HintBox(text: "No balances to collect.");
    return Column(
      children: [for (final row in rows) _BalanceRow(row: row, busy: busyId == row.clientId, onCharge: () => onCharge(row), onWaive: () => onWaive(row))],
    );
  }
}

class _BalanceRow extends StatelessWidget {
  const _BalanceRow({required this.row, required this.busy, required this.onCharge, required this.onWaive});

  final BalanceDue row;
  final bool busy;
  final VoidCallback onCharge;
  final VoidCallback onWaive;

  @override
  Widget build(BuildContext context) {
    final date = row.dateIso == null ? null : niceDate(row.dateIso!);
    final detail = date == null ? row.reason : "${row.reason} · $date";
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.name, style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 4),
            Text(moneyFromCents(row.owedCents), style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 2),
            Text(detail, style: TextStyle(color: AppColors.mute, fontSize: 12)),
            const SizedBox(height: 6),
            Text("Balance due", style: TextStyle(color: AppColors.warning, fontSize: 12, fontWeight: FontWeight.w700)),
            if (row.hasCard == false) ...[
              const SizedBox(height: 6),
              Text("No card on file", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: busy || !row.chargeEnabled ? null : onCharge,
                  child: Text(busy ? "Working…" : "Charge card", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: row.chargeEnabled ? AppColors.gold : AppColors.mute)),
                ),
                TextButton(
                  onPressed: busy ? null : onWaive,
                  child: Text("Waive", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.gold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Clients with a negative balance, with the unpaid fees and card flag
/// filled in. One row per client.
Future<List<BalanceDue>> loadBalancesDue(List<ClientInfo> roster) async {
  if (roster.isEmpty) return const [];
  final balances = await SupabaseService.loadClientBalances(roster.map((c) => c.id).toList());
  final owing = [for (final client in roster) if ((balances[client.id] ?? 0) < 0) client];
  final rows = await Future.wait(owing.map((client) async {
    final ledger = unpaidFeesFromLedgerRows(await SupabaseService.loadClientLedger(client.id));
    final reason = balanceReason(ledger);
    final hasCard = await SupabaseService.clientHasSavedCard(client.id);
    return BalanceDue(
      clientId: client.id,
      name: client.name,
      balanceCents: balances[client.id]!,
      reason: reason.reason,
      dateIso: reason.dateIso,
      hasCard: hasCard,
      canChargeCard: ledger.isNotEmpty,
    );
  }));
  rows.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return rows;
}
