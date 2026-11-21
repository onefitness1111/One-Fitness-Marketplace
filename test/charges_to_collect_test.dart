import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:onefitness/core/supabase/supabase_service.dart";
import "package:onefitness/core/utils/charges_due.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/data/models/charge.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/dashboard_load.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/dashboard/trainer_home_screen.dart";
import "package:onefitness/features/trainer/reports/reports_hub_screen.dart";
import "package:onefitness/features/trainer/shell/trainer_shell_state.dart";

void main() {
  Charge row({
    required String type,
    required String date,
    double? amount = 25,
    String? waivedAt,
    String? stripePaymentIntentId,
    String clientName = "Riley Quinn",
  }) => Charge(
    id: "$type-$date-${stripePaymentIntentId ?? waivedAt ?? "open"}-$amount",
    clientId: "client-1",
    clientName: clientName,
    type: type,
    date: date,
    amount: amount,
    waivedAt: waivedAt,
    stripePaymentIntentId: stripePaymentIntentId,
  );

  group("chargeNeedsCollecting", () {
    test("purchases are already paid, with or without a PaymentIntent", () {
      expect(
        chargeNeedsCollecting(row(type: "purchase", date: "2026-11-21")),
        isFalse,
      );
      expect(
        chargeNeedsCollecting(
          row(
            type: "purchase",
            date: "2026-11-21",
            stripePaymentIntentId: "pi_sale",
          ),
        ),
        isFalse,
      );
    });

    test(
      "a refund and a non-positive amount are not money still to collect",
      () {
        expect(
          chargeNeedsCollecting(
            row(
              type: "refund",
              date: "2026-11-21",
              amount: -25,
              stripePaymentIntentId: "pi_sale",
            ),
          ),
          isFalse,
        );
        expect(
          chargeNeedsCollecting(
            row(type: "manual", date: "2026-11-21", amount: 0),
          ),
          isFalse,
        );
        expect(
          chargeNeedsCollecting(
            row(type: "manual", date: "2026-11-21", amount: null),
          ),
          isFalse,
        );
      },
    );

    test("waived fees are forgiven", () {
      expect(
        chargeNeedsCollecting(
          row(type: "late", date: "2026-11-21", waivedAt: "2026-11-21"),
        ),
        isFalse,
      );
      expect(
        chargeNeedsCollecting(
          row(
            type: "early_termination_fee",
            date: "2026-11-21",
            waivedAt: "2026-11-21",
          ),
        ),
        isFalse,
      );
      expect(
        chargeNeedsCollecting(
          row(type: "manual", date: "2026-11-21", waivedAt: "2026-11-21"),
        ),
        isFalse,
      );
    });

    test("a PaymentIntent means the card was already charged", () {
      expect(
        chargeNeedsCollecting(
          row(
            type: "late",
            date: "2026-11-21",
            stripePaymentIntentId: "pi_fee",
          ),
        ),
        isFalse,
      );
      expect(
        chargeNeedsCollecting(
          row(
            type: "noshow",
            date: "2026-11-21",
            stripePaymentIntentId: "pi_fee",
          ),
        ),
        isFalse,
      );
      expect(
        chargeNeedsCollecting(
          row(
            type: "manual",
            date: "2026-11-21",
            stripePaymentIntentId: "pi_fee",
          ),
        ),
        isFalse,
      );
      expect(
        chargeNeedsCollecting(
          row(
            type: "early_termination_fee",
            date: "2026-11-21",
            stripePaymentIntentId: "  ",
          ),
        ),
        isTrue,
      );
    });

    test(
      "manual, early-termination, late, and no-show rows without a card charge are still due",
      () {
        expect(
          chargeNeedsCollecting(row(type: "manual", date: "2026-11-21")),
          isTrue,
        );
        expect(
          chargeNeedsCollecting(
            row(type: "early_termination_fee", date: "2026-11-21"),
          ),
          isTrue,
        );
        expect(
          chargeNeedsCollecting(row(type: "late", date: "2026-11-21")),
          isTrue,
        );
        expect(
          chargeNeedsCollecting(row(type: "noshow", date: "2026-11-21")),
          isTrue,
        );
      },
    );

    test(
      "the today count skips other days and rows that are already settled",
      () {
        const today = "2026-11-21";
        final due = chargesToCollectOn([
          row(type: "purchase", date: today, stripePaymentIntentId: "pi_sale"),
          row(type: "late", date: today, waivedAt: today),
          row(type: "late", date: today, stripePaymentIntentId: "pi_fee"),
          row(type: "manual", date: today, clientName: "Due today"),
          row(type: "noshow", date: today, clientName: "No-show today"),
          row(type: "manual", date: "2026-11-20", clientName: "Yesterday"),
        ], today);
        expect(due.map((c) => c.clientName), ["Due today", "No-show today"]);
      },
    );
  });

  test("the charges loader reads stripe_payment_intent_id", () {
    expect(chargeSelectColumns.contains("stripe_payment_intent_id"), isTrue);
    final parsed = SupabaseService.chargesFromRows([
      {
        "id": "chg-1",
        "client_id": "client-1",
        "client_name": "Riley Quinn",
        "type": "late",
        "date": "2026-11-21",
        "amount": 15,
        "stripe_payment_intent_id": "pi_123",
      },
      {
        "id": "chg-2",
        "client_id": "client-1",
        "client_name": "Riley Quinn",
        "type": "manual",
        "date": "2026-11-21",
        "amount": 10,
        "stripe_payment_intent_id": "  ",
      },
    ]);
    expect(parsed[0].stripePaymentIntentId, "pi_123");
    expect(parsed[1].stripePaymentIntentId, isNull);
    expect(chargeNeedsCollecting(parsed[0]), isFalse);
    expect(chargeNeedsCollecting(parsed[1]), isTrue);
  });

  test(
    "bootstrap rows that omit the PaymentIntent column are not safe to count",
    () {
      expect(chargeRowsKnowPaymentIntent(const []), isTrue);
      expect(
        chargeRowsKnowPaymentIntent([
          {"id": "1", "stripe_payment_intent_id": null},
          {"id": "2", "stripe_payment_intent_id": "pi_1"},
        ]),
        isTrue,
      );
      expect(
        chargeRowsKnowPaymentIntent([
          {"id": "1", "type": "purchase"},
        ]),
        isFalse,
      );
    },
  );

  test(
    "drawer navigation to Reports clears a ledger opened from the banner",
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final nav = container.read(trainerModeProvider.notifier);
      nav.openReport(realtimeChargesReportKey);
      expect(container.read(trainerModeProvider), "reports");
      expect(nav.pendingReportKey, realtimeChargesReportKey);

      nav.go("dashboard");
      expect(nav.pendingReportKey, isNull);
      nav.go("reports");
      expect(container.read(trainerModeProvider), "reports");
      expect(nav.pendingReportKey, isNull);
    },
  );

  testWidgets(
    "the owner banner counts only unpaid charges and opens the charge ledger",
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final today = isoToday();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(800, 8000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      container.read(trainerAuthProvider.notifier).signIn("owner");
      container.read(chargesProvider.notifier).setAll([
        row(
          type: "purchase",
          date: today,
          amount: 229,
          stripePaymentIntentId: "pi_sale",
          clientName: "Paid Buyer",
        ),
        row(
          type: "late",
          date: today,
          waivedAt: today,
          clientName: "Waived Fee",
        ),
        row(
          type: "late",
          date: today,
          stripePaymentIntentId: "pi_fee",
          clientName: "Card Charged",
        ),
        row(type: "manual", date: today, amount: 15, clientName: "Riley Quinn"),
        row(
          type: "manual",
          date: "2020-01-01",
          amount: 40,
          clientName: "Old fee",
        ),
      ], paymentIntentKnown: true);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: TrainerHomeScreen())),
        ),
      );
      await tester.pump();

      final banner = find.text("1 charge to collect today");
      expect(banner, findsOneWidget);
      await tester.ensureVisible(banner);
      await tester.pump();
      await tester.tap(banner);
      await tester.pump();

      expect(container.read(trainerModeProvider), "reports");
      expect(
        container.read(trainerModeProvider.notifier).pendingReportKey,
        realtimeChargesReportKey,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ReportsHubScreen(
                initialReportKey: container
                    .read(trainerModeProvider.notifier)
                    .pendingReportKey,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text("Real-Time Charges"), findsOneWidget);
      expect(find.text("Search reports…"), findsNothing);
      expect(find.textContaining("Riley Quinn"), findsOneWidget);
      expect(find.textContaining("Old fee"), findsNothing);
    },
  );

  testWidgets(
    "the banner is hidden for a coach, when nothing is unpaid, and before PaymentIntent ids are loaded",
    (tester) async {
      final today = isoToday();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      container.read(trainerAuthProvider.notifier).signIn("owner");
      container.read(chargesProvider.notifier).setAll([
        row(type: "purchase", date: today, stripePaymentIntentId: "pi_sale"),
        row(type: "manual", date: today, waivedAt: today),
      ], paymentIntentKnown: true);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: TrainerHomeScreen())),
        ),
      );
      await tester.pump();
      expect(find.textContaining("to collect today"), findsNothing);

      container.read(chargesProvider.notifier).setAll([
        row(type: "manual", date: today, amount: 15),
      ], paymentIntentKnown: false);
      await tester.pump();
      expect(container.read(chargesPaymentIntentKnownProvider), isFalse);
      expect(find.textContaining("to collect today"), findsNothing);

      container.read(chargesProvider.notifier).setAll([
        row(type: "manual", date: today, amount: 15),
      ], paymentIntentKnown: true);
      container
          .read(trainerAuthProvider.notifier)
          .signIn(container.read(trainersProvider).first.id);
      await tester.pump();
      expect(find.textContaining("to collect today"), findsNothing);
    },
  );
}
