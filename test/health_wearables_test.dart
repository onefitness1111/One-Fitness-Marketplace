import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/health/health_stats.dart";
import "package:onefitness/core/legal/privacy_policy_text.dart";
import "package:onefitness/core/health/health_sync.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/utils/coach_names.dart";
import "package:onefitness/core/widgets/segmented_toggle.dart";
import "package:onefitness/features/client/log_progress/connect_device_sheet.dart";
import "package:onefitness/features/client/log_progress/health_section.dart";
import "package:onefitness/features/client/log_progress/log_progress_screen.dart";
import "package:onefitness/features/trainer/clients/coach_health_section.dart";
import "package:onefitness/features/trainer/clients/progress_tab.dart";
import "package:supabase_flutter/supabase_flutter.dart" show PostgrestException;

void main() {
  setUp(() => AppColors.apply(AppPalette.dark));

  final today = DateTime(2026, 11, 21);

  HealthDay day(int ago, {int? sleep, double? weight}) => HealthDay(
        day: today.subtract(Duration(days: ago)),
        sleepMinutes: sleep,
        weightLb: weight,
      );

  group("consent", () {
    test("a coach sees shared stats only after the client turns sharing on", () {
      expect(
        coachShouldShowHealth(shareWithCoach: false, storageUnavailable: false, hasAnyStat: true),
        isFalse,
      );
      expect(
        coachShouldShowHealth(shareWithCoach: true, storageUnavailable: false, hasAnyStat: true),
        isTrue,
      );
      expect(
        coachShouldShowHealth(shareWithCoach: true, storageUnavailable: false, hasAnyStat: false),
        isFalse,
      );
    });

    test("the share line uses the coach name and not a legal name, phone, or address", () {
      const legal = "Christopher Hale";
      final caption = shareHealthCaption("Coach Chris");
      expect(caption, contains("Coach Chris"));
      expect(caption, contains("Off until you turn it on"));
      expect(caption.toLowerCase(), contains("phone number"));
      expect(caption.toLowerCase(), contains("billing address"));
      expect(caption.toLowerCase(), contains("legal name"));
      expect(exposesLegalCoachName(shown: caption, legalName: legal, coachName: "Coach Chris"), isFalse);
      expect(coachPublicName(coachName: ""), "your coach");
    });
  });

  group("storage that is not applied yet", () {
    final missing = PostgrestException(
      message: "Could not find the table 'public.health_daily_stats' in the schema cache",
      code: "PGRST205",
    );

    test("a missing table is storage, and sharing does not turn on", () {
      expect(healthStorageUnavailable(missing), isTrue);
      expect(healthStorageUnavailable(PostgrestException(message: "relation \"health_connections\" does not exist", code: "42P01")), isTrue);
      expect(healthStorageUnavailable(PostgrestException(message: "new row violates row-level security policy", code: "42501")), isFalse);

      final outcome = persistOutcome(error: missing, requestedShare: true);
      expect(outcome.saved, isFalse);
      expect(outcome.storageUnavailable, isTrue);
      expect(outcome.shareApplied, isFalse);
      expect(
        coachShouldShowHealth(shareWithCoach: true, storageUnavailable: true, hasAnyStat: true),
        isFalse,
      );
      expect(
        healthSaveNote(outcome: outcome, coachName: "Coach Chris"),
        contains("stay on this phone"),
      );
    });

    test("the migration file is in the repo and keeps coach reads behind consent", () {
      final sql = File("supabase/migrations/20261121120000_health_wearables.sql").readAsStringSync().toLowerCase();
      expect(sql, contains("create table if not exists public.health_connections"));
      expect(sql, contains("create table if not exists public.health_daily_stats"));
      expect(sql, contains("create table if not exists public.health_workouts"));
      expect(sql, contains("share_with_coach boolean not null default false"));
      expect(sql, contains("enable row level security"));
      expect(sql, contains("primary_trainer_id"));
      expect(sql, contains("health_shared_with_me"));
      expect(sql, isNot(contains("to anon")));
    });
  });

  group("readings", () {
    test("sleep stages win over a session that includes time awake", () {
      final wake = DateTime(2026, 11, 21, 7);
      NormalizedSample stage(int minutes) => NormalizedSample(
            kind: SampleKind.sleepStage,
            from: wake.subtract(Duration(minutes: minutes)),
            to: wake,
            value: minutes.toDouble(),
          );
      final reading = aggregateHealth(
        now: wake,
        sourceId: "apple_health",
        sourceLabel: "Apple Health",
        workouts: const [],
        samples: [
          stage(120),
          stage(90),
          stage(180),
          NormalizedSample(
            kind: SampleKind.sleepSession,
            from: wake.subtract(const Duration(minutes: 480)),
            to: wake,
            value: 480,
          ),
        ],
      );
      expect(reading.dayOn(wake)!.sleepMinutes, 390);
    });

    test("weight in kilograms is stored in pounds, and today's step total replaces the sum", () {
      final now = DateTime(2026, 11, 21, 18);
      final reading = aggregateHealth(
        now: now,
        sourceId: "health_connect",
        sourceLabel: "Health Connect",
        stepsToday: 8432,
        workouts: [
          HealthWorkout(
            externalId: "w1",
            startedAt: now.subtract(const Duration(minutes: 48)),
            endedAt: now,
            activity: workoutActivityLabel("TRADITIONAL_STRENGTH_TRAINING"),
            energyKcal: 320,
          ),
        ],
        samples: [
          NormalizedSample(kind: SampleKind.steps, from: now, to: now, value: 100),
          NormalizedSample(
            kind: SampleKind.weight,
            from: now,
            to: now,
            value: poundsFrom(70, "KILOGRAM")!,
          ),
        ],
      );
      expect(reading.dayOn(now)!.steps, 8432);
      expect(reading.dayOn(now)!.weightLb, closeTo(154.32, 0.01));
      expect(reading.workouts.single.activity, "Strength");
    });

    test("sleep down 15% and a weight moving toward its goal", () {
      final days = <HealthDay>[
        for (var ago = 13; ago >= 7; ago--) day(ago, sleep: 436),
        for (var ago = 6; ago >= 1; ago--) day(ago, sleep: 370),
        day(0, sleep: 372, weight: 172.4),
        day(30, weight: 176.2),
      ];
      final flags = healthFlags(days: days, today: today, weightGoalLb: 165);
      expect(flags.map((flag) => flag.title), ["Sleep is down 15% this week", "Weight is on target"]);
      expect(flags.first.detail, "6h 12m last night · 7-day average was 7h 16m");
      expect(flags.last.onTarget, isTrue);
      expect(flags.last.detail, contains("down 3.8 lb"));
      expect(flags.last.detail, contains("toward 165"));

      final away = healthFlags(
        days: [day(30, weight: 170), day(0, weight: 174)],
        today: today,
        weightGoalLb: 165,
      );
      expect(away.single.title, "Weight is moving away from the goal");
      expect(away.single.onTarget, isFalse);
    });

    test("Fitbit on iPhone is coming soon, and Android goes through Health Connect", () {
      final ios = connectOptions(HealthPlatform.ios);
      final fitbit = ios.singleWhere((option) => option.id == "fitbit");
      expect(fitbit.comingSoon, isTrue);
      expect(fitbit.canConnect, isFalse);
      expect(ios.where((option) => option.canConnect).map((option) => option.id), ["apple_health"]);

      final android = connectOptions(HealthPlatform.android);
      expect(android.where((option) => option.canConnect).map((option) => option.id), ["health_connect"]);
      final text = android.map((option) => "${option.title} ${option.body}").join(" ").toLowerCase();
      expect(text, contains("fitbit"));
      expect(text, contains("oura"));
      expect(text, contains("samsung"));
      expect(text, isNot(contains("sign in to fitbit")));
    });
  });

  test("the privacy policy says health data is read only and shared only with consent", () {
    final policy = kPrivacyPolicy.replaceAll(RegExp(r"\s+"), " ");
    expect(policy, contains("does not write anything back"));
    expect(policy, contains("only if you turn on sharing"));
    expect(policy, contains("No mobile information will be shared with third parties"));
  });

  testWidgets("the shared toggle's highlight slides, then sits on the tapped segment", (tester) async {
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SegmentedToggle(
              labels: const ["Overview", "Body", "Lifts", "Photos"],
              index: index,
              itemKeys: const [
                Key("slide-overview"),
                Key("slide-body"),
                Key("slide-lifts"),
                Key("slide-photos"),
              ],
              onChanged: (next) => setState(() => index = next),
            ),
          ),
        ),
      ),
    );

    BoxDecoration fillOf(String key) {
      final fill = tester.widgetList<Container>(
        find.descendant(of: find.byKey(Key(key)), matching: find.byType(Container)),
      ).firstWhere((container) => container.decoration is BoxDecoration);
      return fill.decoration as BoxDecoration;
    }

    expect(fillOf("slide-overview").color, AppColors.gold);

    await tester.tap(find.byKey(const Key("slide-photos")));
    await tester.pump();
    final sliding = tester.widgetList<Transform>(find.byType(Transform)).where((transform) {
      return transform.transform.getTranslation().x.abs() > 1;
    });
    expect(sliding, isNotEmpty);

    await tester.pumpAndSettle();
    expect(fillOf("slide-photos").color, AppColors.gold);
    expect(
      tester.widgetList<Transform>(find.byType(Transform)).where((transform) => transform.transform.getTranslation().x.abs() > 1),
      isEmpty,
    );
  });

  testWidgets("each Log Progress segment shows only its own content", (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: LogProgressScreen()))));
    await tester.pump();

    expect(find.text("Connect a device"), findsOneWidget);
    expect(find.text("Share health stats with my coach"), findsOneWidget);
    expect(find.textContaining("Marcus Rivera"), findsNothing);
    expect(find.textContaining("Alex Morgan"), findsNothing);
    expect(find.textContaining("18185559876"), findsNothing);
    expect(find.text("Bodyweight Over Time"), findsNothing);
    expect(find.text("CHOOSE EXERCISES TO CHART (MAX 6)"), findsNothing);
    expect(find.text("Add photo"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-body")));
    await tester.pump();
    expect(find.text("Bodyweight Over Time"), findsOneWidget);
    expect(find.text("30d"), findsWidgets);
    expect(find.text("Set a goal"), findsOneWidget);
    expect(find.text("Share results card"), findsOneWidget);
    expect(find.text("Connect a device"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-lifts")));
    await tester.pump();
    expect(find.text("CHOOSE EXERCISES TO CHART (MAX 6)"), findsOneWidget);
    expect(find.text("Barbell Bench Press"), findsOneWidget);
    expect(find.text("Bodyweight Over Time"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-photos")));
    await tester.pump();
    expect(find.text("Add photo"), findsOneWidget);
    expect(find.text("Barbell Bench Press"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-overview")));
    await tester.pump();
    expect(find.text("Connect a device"), findsOneWidget);
    expect(find.text("Add photo"), findsNothing);
  });

  testWidgets("each coach Progress segment shows only its own content", (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: Scaffold(body: ProgressTab(clientId: "demo-alex")))),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining("No health stats shared yet"), findsOneWidget);
    expect(find.text("MEASUREMENTS"), findsNothing);
    expect(find.text("CHOOSE EXERCISES TO CHART (MAX 6)"), findsNothing);
    expect(find.text("PROGRESS PHOTOS"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-body")));
    await tester.pump();
    expect(find.text("MEASUREMENTS"), findsOneWidget);
    expect(find.textContaining("Weight:"), findsWidgets);
    expect(find.text("COACH COMMENT"), findsWidgets);
    expect(find.textContaining("No health stats shared yet"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-lifts")));
    await tester.pump();
    expect(find.text("CHOOSE EXERCISES TO CHART (MAX 6)"), findsOneWidget);
    expect(find.text("Barbell Bench Press"), findsOneWidget);
    expect(find.text("Share with Squad"), findsNothing);
    expect(find.text("MEASUREMENTS"), findsNothing);

    await tester.tap(find.byKey(const Key("progress-segment-photos")));
    await tester.pump();
    expect(find.text("PROGRESS PHOTOS"), findsOneWidget);
    expect(find.text("Add a photo for this client"), findsOneWidget);
    expect(find.text("Barbell Bench Press"), findsNothing);
  });

  testWidgets("the coach overview shows shared stats only when the client consented", (tester) async {
    final reading = _sampleReading();
    Future<void> pump(bool share) {
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CoachHealthSection(
                key: ValueKey(share),
                clientId: "demo-alex",
                load: (_) async => share ? HealthCoachPayload(reading: reading, shareWithCoach: true) : null,
              ),
            ),
          ),
        ),
      );
    }

    await pump(false);
    await tester.pumpAndSettle();
    expect(find.text("Sleep is down 15% this week"), findsNothing);
    expect(find.textContaining("No health stats shared yet"), findsOneWidget);

    await pump(true);
    await tester.pumpAndSettle();
    expect(find.textContaining("8,432"), findsWidgets);
    expect(find.text("Strength"), findsOneWidget);
    expect(find.text("Trends vs. goals"), findsOneWidget);
  });

  testWidgets("without the tables, the client still sees on-device stats and sharing stays off", (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: HealthSection(
              platform: HealthPlatform.ios,
              resolveAccount: false,
              accountId: "client-1",
              read: () async {
                reads += 1;
                return _sampleReading();
              },
              save: (reading, share) async => persistOutcome(
                error: PostgrestException(
                  message: "Could not find the table 'public.health_daily_stats' in the schema cache",
                  code: "PGRST205",
                ),
                requestedShare: share,
              ),
            ),
          ),
        ),
      ),
    );
    expect(reads, 0);
    await tester.tap(find.text("Connect a device"));
    await tester.pumpAndSettle();
    expect(find.text("Continue with Apple Health"), findsOneWidget);
    expect(find.text("Coming soon"), findsOneWidget);
    expect(find.text("Sign in to Fitbit"), findsNothing);
    expect(reads, 0);

    await tester.tap(find.text("Continue with Apple Health"));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.textContaining("8,432"), findsWidgets);
    expect(find.text("Strength"), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const Key("share-health-toggle"))).value, isFalse);
    expect(find.textContaining("stay on this phone"), findsOneWidget);
  });

  testWidgets("Android explains Health Connect and does not offer a Fitbit sign-in", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showConnectDeviceSheet(context, platform: HealthPlatform.android),
              child: const Text("open"),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
    expect(find.text("Continue with Health Connect"), findsOneWidget);
    expect(find.text("Coming soon"), findsNothing);
    expect(find.text("Sign in to Fitbit"), findsNothing);
    expect(find.textContaining("Fitbit"), findsWidgets);
  });
}

HealthReading _sampleReading() {
  final now = DateTime.now();
  return HealthReading(
    days: [
      HealthDay(
        day: dateOnly(now),
        steps: 8432,
        activeKcal: 612,
        restingHr: 58,
        heartRate: 72,
        sleepMinutes: 372,
        hrvMs: 42,
        weightLb: 172.4,
        bodyFatPct: 18.2,
        leanMassLb: 141,
      ),
    ],
    workouts: [
      HealthWorkout(
        externalId: "w1",
        startedAt: now.subtract(const Duration(minutes: 48)),
        endedAt: now,
        activity: "Strength",
        energyKcal: 320,
      ),
    ],
    syncedAt: now,
    sourceId: "apple_health",
    sourceLabel: "Apple Health",
    deviceNames: const {"Apple Watch"},
  );
}
