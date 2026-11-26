import "package:onefitness/data/models/client_info.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/utils/points_ledger_utils.dart";
import "package:onefitness/core/utils/rewards_domain.dart";
import "package:onefitness/data/models/points_ledger_entry.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/features/client/rewards/rewards_screen.dart";

void main() {
  final now = DateTime.parse("2026-11-25T12:00:00Z");

  PointsLedgerEntry earn(String id, int amount, {String clientId = "c1"}) => PointsLedgerEntry(
        id: id,
        clientId: clientId,
        amount: amount,
        type: "earn",
        source: "challenge_1st",
        createdAt: "2026-11-01T12:00:00Z",
        expiresAt: "2027-05-01T12:00:00Z",
      );

  test("L8 constants and planRedemption enforce 40 min, 100 max, and no balance cap", () {
    expect(kRewardMinRedeemPoints, 40);
    expect(kRewardMaxRedeemPoints, 100);

    final underMin = replayLedger([earn("e1", 39)], now: now);
    expect(underMin.balance, 39);
    expect(planRedemption(underMin.lots, now: now), isNull);

    final atMin = replayLedger([earn("e1", 40)], now: now);
    expect(planRedemption(atMin.lots, now: now)?.points, 40);
    expect(pointsToDiscountCents(40, 10000), 2000);

    final mid = replayLedger([earn("e1", 75)], now: now);
    expect(planRedemption(mid.lots, now: now)?.points, 75);
    expect(pointsToDiscountCents(75, 10000), 3750);

    final overCap = replayLedger([earn("e1", 60), earn("e2", 80)], now: now);
    expect(overCap.balance, 140);
    expect(planRedemption(overCap.lots, now: now)?.points, 100);
    expect(pointsToDiscountCents(100, 10000), 5000);

    // Even if a caller passes a higher cap or lower min, bounds stay 40..100.
    expect(planRedemption(overCap.lots, now: now, capPoints: 200, minPoints: 10)?.points, 100);
    expect(planRedemption(underMin.lots, now: now, capPoints: 100, minPoints: 10), isNull);
  });

  Future<void> pumpRewards(WidgetTester tester, List<PointsLedgerEntry> entries) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(pointsLedgerProvider.notifier).replaceForClient("c1", entries);
    container.read(clientInfoProvider.notifier).update((_) => const ClientInfo(id: "c1", name: "Test Client"));
    container.read(earnedBadgesProvider.notifier).setAll(const []);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: RewardsScreen(clientId: "c1")),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets("RewardsScreen shows clear 40-100 rules and locks below 40", (tester) async {
    await pumpRewards(tester, [earn("e1", 25)]);
    expect(find.text("25"), findsOneWidget);
    expect(find.textContaining("40 and 100 points"), findsOneWidget);
    expect(find.textContaining("no cap on your balance"), findsOneWidget);
    expect(find.textContaining("You have 25 — 15 more to go"), findsOneWidget);
  });

  testWidgets("RewardsScreen lets clients accumulate past 100 and caps single redemption at 100", (tester) async {
    await pumpRewards(tester, [earn("e1", 60), earn("e2", 80)]);
    expect(find.text("140"), findsOneWidget);
    expect(find.text("Redeem 100 points on my next purchase"), findsOneWidget);
    expect(find.textContaining("Applies automatically as 50% off at checkout"), findsOneWidget);
    expect(find.textContaining("40 points will stay in your balance"), findsOneWidget);
  });

  testWidgets("RewardsScreen redeems exact balance between 40 and 100", (tester) async {
    await pumpRewards(tester, [earn("e1", 75)]);
    expect(find.text("75"), findsOneWidget);
    expect(find.text("Redeem 75 points on my next purchase"), findsOneWidget);
    expect(find.textContaining("37.5% off"), findsOneWidget);
  });
}
