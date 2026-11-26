import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/motion/skeleton.dart";
import "package:onefitness/core/widgets/fade_slide_in.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/providers/dashboard_extras.dart";
import "package:onefitness/features/client/dashboard/client_dashboard_screen.dart";
import "package:onefitness/features/trainer/dashboard/trainer_home_screen.dart";

void main() {
  testWidgets("the client dashboard's first frame has no component loading state", (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: const MaterialApp(
        home: ClientDashboardScreen(
          client: ClientRecord(id: "c1"),
          info: ClientInfo(id: "c1", name: "Alex Johnson"),
          plan: null,
          bookings: [],
          earnedBadges: [],
          onGoBooking: _noop,
          onLogWorkout: _noop,
          onPickDate: _ignore,
          onGoHabits: _noop,
          onGoToForm: _ignore,
          onGoMemberships: _noop,
        ),
      ),
    ));

    _expectReady(tester);
    expect(find.textContaining("Hey Alex"), findsOneWidget);
    final book = find.text("Book a session");
    await tester.ensureVisible(book);
    await tester.tap(book);
    await tester.pump();
    _expectReady(tester);
  });

  testWidgets("the coach dashboard's first frame has no component loading state", (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: TrainerHomeScreen()),
    ));

    _expectReady(tester);
    expect(find.textContaining("Hi,"), findsOneWidget);
    expect(find.text("NEEDS ATTENTION"), findsOneWidget);
    expect(find.text("Sign out"), findsOneWidget);
  });

  testWidgets("a filled balance and renewal are on the first client frame", (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dashboardExtrasProvider.overrideWith(() => _ReadyExtras()),
      ],
      child: const MaterialApp(
        home: ClientDashboardScreen(
          client: ClientRecord(id: "c1"),
          info: ClientInfo(id: "c1", name: "Alex Johnson"),
          plan: null,
          bookings: [],
          earnedBadges: [],
          onGoBooking: _noop,
          onLogWorkout: _noop,
          onPickDate: _ignore,
          onGoHabits: _noop,
          onGoToForm: _ignore,
          onGoMemberships: _noop,
        ),
      ),
    ));

    _expectReady(tester);
    expect(find.text("Pay now"), findsOneWidget);
    expect(find.text("Renew now"), findsOneWidget);
  });
}

void _noop() {}

void _ignore(String _) {}

void _expectReady(WidgetTester tester) {
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(find.byType(LinearProgressIndicator), findsNothing);
  expect(find.byType(FadeSlideIn), findsNothing);
  expect(find.byType(Skeleton), findsNothing);
  expect(find.textContaining("Loading"), findsNothing);
  expect(find.textContaining("loading"), findsNothing);
}

class _ReadyExtras extends DashboardExtrasNotifier {
  @override
  DashboardExtras build() => const DashboardExtras(
        balanceCents: -1200,
        renewals: [
          {
            "offer": "full",
            "planId": "p1",
            "planName": "10 Sessions",
            "enrollmentStart": "2026-01-01",
            "remaining": 2,
            "priceCents": 10000,
            "chargeCents": 10000,
          },
        ],
      );
}
