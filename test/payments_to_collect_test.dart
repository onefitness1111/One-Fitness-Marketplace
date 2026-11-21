import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/utils/payments_to_collect.dart";
import "package:onefitness/features/trainer/payments/collect_payments_screen.dart";

void main() {
  test("a negative balance counts, and a zero or credit does not", () {
    expect(paymentsToCollectCount(balanceCents: [0, 500, -1, -2500]), 2);
    expect(paymentsToCollectCount(balanceCents: const []), 0);
    expect(paymentsToCollectLabel(0), "0 payments to collect");
    expect(paymentsToCollectLabel(1), "1 payment to collect");
    expect(paymentsToCollectLabel(3), "3 payments to collect");
  });

  test("unresolved declined charges add to the balance count", () {
    expect(
      paymentsToCollectCount(balanceCents: [-1000], unresolvedDeclinedCharges: 2),
      3,
    );
    expect(
      paymentsToCollectCount(balanceCents: const [0], unresolvedDeclinedCharges: 0),
      0,
    );
  });

  test("the count is not limited to today", () {
    expect(paymentsToCollectCount(balanceCents: [-4000, -100]), 2);
  });

  test("ledger rows become a reason and the latest date", () {
    final fees = unpaidFeesFromLedgerRows([
      {"status": "paid", "fee_type": "late", "amount_cents": 1500, "created_at": "2026-11-01T12:00:00Z"},
      {"status": "unpaid", "fee_type": "noshow", "amount_cents": 2500, "created_at": "2026-11-20T15:00:00Z"},
      {"status": "unpaid", "fee_type": "late", "amount_cents": 1500, "created_at": "2026-11-18"},
      {"status": "waived", "fee_type": "close", "amount_cents": 2500, "created_at": "2026-11-21"},
    ]);
    expect(fees.map((f) => f.kind), ["noshow", "late"]);
    final reason = balanceReason(fees);
    expect(reason.reason, "No-show, Late cancellation");
    expect(reason.dateIso, "2026-11-20");
    expect(balanceReason(const []).reason, "Account balance");
  });

  testWidgets("Balances lists who owes what, and Declined is empty", (tester) async {
    AppColors.apply(AppPalette.dark);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(balanceDuesProvider.notifier).setAll([
      const BalanceDue(
        clientId: "a",
        name: "Sample Client A",
        balanceCents: -2500,
        reason: "No-show",
        dateIso: "2026-11-21",
        hasCard: true,
        canChargeCard: true,
      ),
      const BalanceDue(
        clientId: "b",
        name: "Sample Client B",
        balanceCents: -1500,
        reason: "Late cancellation",
        dateIso: "2026-11-20",
        hasCard: false,
        canChargeCard: true,
      ),
    ]);
    String? charged;
    String? waived;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.current,
          home: Scaffold(
            body: CollectPaymentsScreen(
              load: () async {},
              chargeBalance: (id) async {
                charged = id;
                return null;
              },
              waiveBalance: (id) async {
                waived = id;
                return 0;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining("Declined charges aren't kept"), findsOneWidget);
    expect(find.text("Sample Client A"), findsNothing);

    await tester.tap(find.text("Balances"));
    await tester.pumpAndSettle();
    expect(find.text("Sample Client A"), findsOneWidget);
    expect(find.text("Sample Client B"), findsOneWidget);
    expect(find.text("No card on file"), findsOneWidget);
    expect(find.text("Balance due"), findsNWidgets(2));

    await tester.tap(find.text("Charge card").first);
    await tester.pumpAndSettle();
    expect(find.textContaining("Sample Client A's saved card"), findsOneWidget);
    await tester.tap(find.text("Charge card").last);
    await tester.pumpAndSettle();
    expect(charged, "a");
    expect(find.text("Sample Client A"), findsNothing);

    await tester.tap(find.text("Waive"));
    await tester.pumpAndSettle();
    expect(find.textContaining("Waive Sample Client B"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "Waive").last);
    await tester.pumpAndSettle();
    expect(waived, "b");
    expect(find.text("No balances to collect."), findsOneWidget);
  });
}
