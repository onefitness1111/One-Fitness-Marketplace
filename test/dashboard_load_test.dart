import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/features/auth/signing_in_label.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:supabase_flutter/supabase_flutter.dart" show PostgrestException;

import "package:onefitness/core/supabase/supabase_service.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/data/cache/bootstrap_cache.dart";
import "package:onefitness/core/json/off_main_json.dart";
import "package:onefitness/core/startup/launch_timing.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/comm_message.dart";
import "package:onefitness/data/models/measurement.dart";
import "package:onefitness/data/models/progress_goal.dart";
import "package:onefitness/data/models/progress_photo.dart";
import "package:onefitness/data/models/workout_log.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/dashboard_load.dart";
import "package:onefitness/data/providers/supabase_bootstrap_provider.dart";

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetSectionsForTest();
  });

  test("the dashboard booking window is today, two weeks back, and two weeks ahead", () {
    final window = dashboardBookingWindow(DateTime(2026, 11, 21));
    expect(window.from, isoDate(DateTime(2026, 11, 7)));
    expect(window.to, isoDate(DateTime(2026, 12, 5)));
    expect(dashboardBookingLookbackDays, 14);
    expect(dashboardBookingLookaheadDays, 14);
  });

  test("the home screen paints before the rest of the gym", () {
    expect(shellBeforeFullGymDownload("client"), isTrue);
    expect(shellBeforeFullGymDownload("coach"), isTrue);
    expect(shellBeforeFullGymDownload("owner"), isTrue);
    expect(shellBeforeFullGymDownload(null), isFalse);
  });

  test("a cold launch is one wave with the bootstrap rpc and two without it", () {
    expect(coldLaunchWaves(bootstrapRpc: true), 1);
    expect(coldLaunchWaves(bootstrapRpc: false), 2);
  });

  test("sign-in waits on one client round and two staff rounds", () {
    expect(blockingSignInRounds("client"), 1);
    expect(blockingSignInRounds("coach"), 2);
    expect(blockingSignInRounds("owner"), 2);
  });

  test("the sign-in button does not wait on the duplicate directory, contacts, or program blobs", () {
    final client = blockingSignInReads("client");
    expect(client.contains("profile_directory"), isFalse);
    expect(client.contains("profile_contact_for"), isFalse);
    expect(client.contains("bookings"), isTrue);
    expect(client.contains("clients"), isTrue);
    expect(backgroundSignInReads("client").contains("profile_directory"), isTrue);
    expect(backgroundSignInReads("client").contains("profile_contact_for"), isTrue);
    expect(backgroundSignInReads("client").contains("client_records_home"), isTrue);

    final staff = blockingSignInReads("coach");
    expect(staff.contains("profile_directory"), isTrue);
    expect(staff.contains("profile_contact_for"), isFalse);
    expect(backgroundSignInReads("owner").contains("profile_contact_for"), isTrue);
    expect(backgroundSignInReads("coach").contains("client_records_programs"), isTrue);
  });

  test("the client home record leaves programs and nutrition for later", () {
    expect(clientHomeRecordColumns.contains("savedPrograms"), isFalse);
    expect(clientHomeRecordColumns.contains("nutrition"), isFalse);
    expect(clientHomeRecordColumns.contains("habitSettings"), isTrue);
    expect(clientHomeRecordColumns.contains("workoutLogs"), isTrue);
    expect(clientHomeRecordColumns.contains("signatures"), isTrue);
    expect(staffDetailRecordColumns.contains("savedPrograms"), isTrue);
    expect(staffDetailRecordColumns.contains("nutrition"), isTrue);
  });

  test("any dashboard bootstrap error falls back to the existing queries", () async {
    final missing = PostgrestException(
      message: "Could not find the function public.dashboard_bootstrap(p_from, p_to) in the schema cache",
      code: "PGRST202",
    );
    final ambiguous = PostgrestException(
      message: 'column reference "role" is ambiguous',
      code: "42702",
    );
    final transport = Exception("socket exception");

    expect(dashboardBootstrapNeedsFallback(error: missing), isTrue);
    expect(dashboardBootstrapNeedsFallback(error: ambiguous), isTrue);
    expect(dashboardBootstrapNeedsFallback(error: transport), isTrue);
    expect(dashboardBootstrapNeedsFallback(payload: null), isTrue);
    expect(dashboardBootstrapNeedsFallback(payload: {"role": "owner"}), isTrue);
    expect(dashboardBootstrapNeedsFallback(payload: {"directory": <dynamic>[]}), isFalse);

    Future<Map<String, dynamic>?> read(Future<dynamic> Function() call) {
      return SupabaseService.fetchDashboardBootstrap(from: "2026-11-07", to: "2026-12-05", call: call);
    }

    expect(await read(() async => throw missing), isNull);
    expect(await read(() async => throw ambiguous), isNull);
    expect(await read(() async => throw transport), isNull);
    expect(await read(() async => throw "function not found"), isNull);

    final hit = await read(() async => {"directory": <dynamic>[], "role": "client"});
    expect(hit?["directory"], isA<List>());
    expect(dashboardBootstrapNeedsFallback(payload: hit), isFalse);
  });

  test("the coach's first record read leaves workout logs out", () {
    expect(coachDashboardRecordColumns.contains("workoutLogs"), isFalse);
    expect(coachDashboardRecordColumns.contains("programDays"), isFalse);
    expect(coachDashboardRecordColumns.contains("savedPrograms"), isTrue);
    expect(coachDashboardRecordColumns.contains("nutrition"), isTrue);
    expect(fullDashboardRecordColumns.contains("workoutLogs"), isTrue);
    expect(bookingSelectColumns.contains("client_id"), isTrue);
    expect(bookingSelectColumns.contains("*"), isFalse);
  });

  test("opening chat or the shop does not happen during the dashboard read", () {
    expect(sectionsForClientScreen("dashboard"), {GymSection.badges});
    expect(sectionsForClientScreen("chat"), {GymSection.messages});
    expect(sectionsForClientScreen("shop"), {GymSection.products});
    expect(sectionsForClientScreen("history"), {GymSection.bookingsRest});
    expect(sectionsForStaffScreen("dashboard"), isEmpty);
    expect(sectionsForStaffScreen("schedule"), contains(GymSection.bookingsRest));
    expect(sectionsForStaffScreen("schedule"), contains(GymSection.blocked));
    expect(sectionsForStaffScreen("chat"), {GymSection.messages});
  });

  test("a large snapshot decodes off the caller and round-trips", () async {
    final raw = "{\"hello\":\"${'x' * (offMainJsonBytes + 8)}\"}";
    final decoded = await decodeJsonOffMain(raw);
    expect(decoded, isA<Map>());
    expect((decoded as Map)["hello"], startsWith("xxx"));

    final encoded = await encodeJsonOffMain({"hello": "a"}, weight: offMainJsonBytes);
    expect(encoded, contains("hello"));
  });

  testWidgets("the sign-in button shows a spinner while it waits", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: SigningInLabel()))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text("Signing in…"), findsOneWidget);
  });

  test("launch timings can be marked more than once", () {
    LaunchTiming.markProcessStart();
    LaunchTiming.markProcessStart();
    LaunchTiming.markFirstFrame();
    LaunchTiming.markSessionRestored();
    LaunchTiming.markDashboardUsable("test");
    LaunchTiming.markDashboardUsable("again");
    LaunchTiming.phase("step");
  });

  test("the snapshot is keyed per user and sign-out clears it", () async {
    await BootstrapCache.write("user-a", {"hello": "a"});
    expect((await BootstrapCache.read("user-a"))?["hello"], "a");

    await BootstrapCache.deleteFor("user-a");
    expect(await BootstrapCache.read("user-a"), isNull);

    await BootstrapCache.write("user-a", {"hello": "a"});
    await BootstrapCache.activate("user-b");
    expect(await BootstrapCache.read("user-a"), isNull);
    await BootstrapCache.write("user-b", {"hello": "b"});
    expect((await BootstrapCache.read("user-b"))?["hello"], "b");
    expect(await BootstrapCache.read("user-a"), isNull);
  });

  test("plans and progress column lists stay slim and never gate on primary_trainer_id", () {
    expect(clientPlansRecordColumns.contains("savedPrograms"), isTrue);
    expect(clientPlansRecordColumns.contains("nutrition"), isTrue);
    expect(clientPlansRecordColumns.contains("programDays"), isTrue);
    expect(clientPlansRecordColumns.contains("savedNutritionPrograms"), isTrue);
    expect(clientPlansRecordColumns.contains("foodLog"), isTrue);
    expect(clientPlansRecordColumns.contains("myMeals"), isTrue);
    expect(clientPlansRecordColumns.contains("photos"), isFalse);
    expect(clientPlansRecordColumns.contains("primary_trainer_id"), isFalse);

    expect(clientProgressRecordColumns.contains("measurements"), isTrue);
    expect(clientProgressRecordColumns.contains("progressGoal"), isTrue);
    expect(clientProgressRecordColumns.contains("photos"), isTrue);
    expect(clientProgressRecordColumns.contains("primary_trainer_id"), isFalse);

    expect(sectionsForClientScreen("plans"), contains(GymSection.clientPlans));
    expect(sectionsForClientScreen("plans"), isNot(contains(GymSection.clientProgress)));
    expect(sectionsForClientScreen("nutrition"), contains(GymSection.clientPlans));
    expect(sectionsForClientScreen("nutrition"), isNot(contains(GymSection.clientProgress)));
    expect(sectionsForClientScreen("day"), contains(GymSection.clientPlans));

    for (final screen in ["progress", "photos", "measurements"]) {
      expect(sectionsForClientScreen(screen), {GymSection.clientProgress});
    }
  });

  test("recordsFromDashboardRows and recordPayloadFromRow pass through Plans and Log Progress fields", () {
    final rows = [
      {
        "profile_id": "client-1",
        "savedPrograms": [
          {
            "id": "prog-1",
            "name": "3-Day Split",
            "status": "active",
            "programDays": [
              {
                "id": "day-1",
                "title": "Full Body",
                "exercises": [],
              },
            ],
          },
        ],
        "nutrition": {
          "targets": {
            "training": {"calories": "2200", "protein": "32", "carbs": "40", "fats": "28", "water": "4"},
            "rest": {"calories": "2000", "protein": "34", "carbs": "33", "fats": "33", "water": "3"},
          },
          "mealBudgets": {
            "training": {"breakfast": "450"},
            "rest": {"breakfast": "400"},
          },
        },
        "data->programDays": [
          {"id": "day-live", "title": "Upper", "exercises": []},
        ],
        "savedNutritionPrograms": [
          {
            "id": "nut-1",
            "name": "Cut",
            "type": "nutrition",
            "status": "active",
            "targets": {
              "training": {"calories": "2200"},
              "rest": {"calories": "2000"},
            },
          },
        ],
        "foodLog": {
          "days": {
            "2026-11-24": {
              "breakfast": [
                {"id": "f1", "name": "Oats", "qty": 1, "unit": "bowl", "calories": 350, "protein": 12, "carbs": 55, "fats": 7},
              ],
            },
          },
        },
        "myMeals": {
          "breakfast": [
            {"id": "m1", "name": "Egg Whites", "calories": 300, "protein": 30, "carbs": 20, "fats": 8},
          ],
        },
        "measurements": [
          {"id": "meas-1", "date": "2026-11-20", "weight": "165"},
        ],
        "progressGoal": {"kind": "weight", "field": "weight", "target": 155, "start": 170, "unit": "lb"},
        "photos": [
          {"id": "ph-1", "date": "2026-11-20", "img": "client-1/ph-1.jpg"},
        ],
      },
    ];

    final payload = SupabaseService.recordPayloadFromRow(rows.first);
    expect(payload["savedPrograms"], isA<List>());
    expect(payload["nutrition"], isA<Map>());
    expect(payload["programDays"], isA<List>());
    expect(payload["savedNutritionPrograms"], isA<List>());
    expect(payload["foodLog"], isA<Map>());
    expect(payload["myMeals"], isA<Map>());
    expect(payload["measurements"], isA<List>());
    expect(payload["progressGoal"], isA<Map>());
    expect(payload["photos"], isA<List>());

    final rec = SupabaseService.recordsFromDashboardRows(rows)["client-1"];
    expect(rec, isNotNull);
    expect(rec!.savedPrograms, hasLength(1));
    expect(rec.savedPrograms.first.status, "active");
    expect(rec.savedPrograms.first.programDays, hasLength(1));
    expect(rec.nutrition, isNotNull);
    expect(rec.nutrition!.trainingTargets.calories, "2200");
    expect(rec.nutrition!.mealBudgets.training["breakfast"], "450");
    expect(rec.programDays, hasLength(1));
    expect(rec.savedNutritionPrograms, hasLength(1));
    expect(rec.foodLog.totalsFor("2026-11-24").calories, 350);
    expect(rec.myMeals["breakfast"], hasLength(1));
    expect(rec.measurements, hasLength(1));
    expect(rec.measurements.first.weight, "165");
    expect(rec.progressGoal?.target, 155);
    expect(rec.photos, hasLength(1));
  });

  test("opening Plans loads and merges workout and nutrition programs without dropping home or progress data", () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(clientRecordProvider.notifier).update(
          (_) => const ClientRecord(
            id: "client-42",
            habits: ["water"],
            tourSeenDashboard: true,
            workoutLogs: [
              WorkoutLogEntry(
                id: "wl-1",
                date: "2026-11-20",
                loggedAt: "2026-11-20T09:00:00",
                programId: "prog-1",
                programName: "3-Day Split",
                dayId: "day-1",
                dayTitle: "Full Body",
              ),
            ],
            measurements: [Measurement(id: "m-1", date: "2026-11-18", weight: "160")],
            photos: [ProgressPhoto(id: "p-1", date: "2026-11-18", img: "client-42/p-1.jpg")],
            progressGoal: ProgressGoal(kind: "weight", field: "weight", target: 150),
            comms: [CommMessage(id: "c-1", who: "coach", text: "Great job", at: "2026-11-20T10:00:00")],
          ),
        );

    final calls = <(String columns, String? profileId)>[];
    await ensureClientSections(
      container,
      "plans",
      clientId: "client-42",
      fetchRecordRows: (columns, {String? profileId}) async {
        calls.add((columns, profileId));
        return [
          {
            "profile_id": "client-42",
            "savedPrograms": [
              {
                "id": "prog-1",
                "name": "3-Day Split",
                "status": "active",
                "programDays": [
                  {"id": "day-1", "title": "Full Body", "exercises": []},
                ],
              },
            ],
            "nutrition": {
              "targets": {
                "training": {"calories": "2200", "protein": "32", "carbs": "40", "fats": "28", "water": "4"},
                "rest": {"calories": "2000", "protein": "34", "carbs": "33", "fats": "33", "water": "3"},
              },
              "guidelines": "Stay hydrated",
            },
            "programDays": [
              {"id": "day-1", "title": "Full Body", "exercises": []},
            ],
            "savedNutritionPrograms": [
              {
                "id": "nut-1",
                "name": "Custom Nutrition",
                "type": "nutrition",
                "status": "active",
                "targets": {
                  "training": {"calories": "2200"},
                  "rest": {"calories": "2000"},
                },
              },
            ],
            "foodLog": {
              "days": {
                "2026-11-24": {
                  "lunch": [
                    {"id": "fl-1", "name": "Chicken Bowl", "qty": 1, "unit": "bowl", "calories": 600, "protein": 45, "carbs": 55, "fats": 18},
                  ],
                },
              },
            },
            "myMeals": {
              "breakfast": [
                {"id": "mm-1", "name": "Yogurt Parfait", "calories": 320, "protein": 24, "carbs": 35, "fats": 9},
              ],
            },
          },
        ];
      },
    );

    expect(calls, [(clientPlansRecordColumns, "client-42")]);
    final merged = container.read(clientRecordProvider);
    expect(merged.savedPrograms, hasLength(1));
    expect(merged.savedPrograms.first.programDays, hasLength(1));
    expect(merged.nutrition?.trainingTargets.calories, "2200");
    expect(merged.nutrition?.guidelines, "Stay hydrated");
    expect(merged.programDays, hasLength(1));
    expect(merged.savedNutritionPrograms, hasLength(1));
    expect(merged.foodLog.totalsFor("2026-11-24").calories, 600);
    expect(merged.myMeals["breakfast"], hasLength(1));

    // Home-read, Log Progress, and comms fields stay intact.
    expect(merged.habits, ["water"]);
    expect(merged.tourSeenDashboard, isTrue);
    expect(merged.workoutLogs, hasLength(1));
    expect(merged.measurements, hasLength(1));
    expect(merged.photos, hasLength(1));
    expect(merged.progressGoal?.target, 150);
    expect(merged.comms, hasLength(1));

    // Re-entering nutrition does not trigger a duplicate fetch once loaded.
    await ensureClientSections(
      container,
      "nutrition",
      clientId: "client-42",
      fetchRecordRows: (columns, {String? profileId}) async {
        calls.add((columns, profileId));
        return const [];
      },
    );
    expect(calls, hasLength(1));
  });

  test("opening Log Progress loads and merges measurements, goal, and photos without dropping home or Plans data", () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initial = SupabaseService.recordsFromDashboardRows([
      {
        "profile_id": "client-42",
        "habitSettings": {"enabled": ["steps"]},
        "savedPrograms": [
          {
            "id": "prog-1",
            "name": "Upper / Lower",
            "status": "active",
            "programDays": [
              {"id": "day-1", "title": "Upper", "exercises": []},
            ],
          },
        ],
        "nutrition": {
          "targets": {
            "training": {"calories": "2100"},
            "rest": {"calories": "1900"},
          },
        },
      },
    ])["client-42"]!;
    container.read(clientRecordProvider.notifier).update((_) => initial);

    final calls = <(String columns, String? profileId)>[];
    await ensureClientSections(
      container,
      "progress",
      clientId: "client-42",
      fetchRecordRows: (columns, {String? profileId}) async {
        calls.add((columns, profileId));
        return [
          {
            "profile_id": "client-42",
            "measurements": [
              {"id": "meas-1", "date": "2026-11-22", "weight": "172", "waist": "31"},
            ],
            "progressGoal": {"kind": "weight", "field": "weight", "target": 165, "start": 178, "unit": "lb"},
            "photos": [
              {"id": "ph-1", "date": "2026-11-22", "img": "client-42/ph-1.jpg"},
            ],
          },
        ];
      },
    );

    expect(calls, [(clientProgressRecordColumns, "client-42")]);
    final merged = container.read(clientRecordProvider);
    expect(merged.measurements, hasLength(1));
    expect(merged.measurements.first.weight, "172");
    expect(merged.progressGoal?.target, 165);
    expect(merged.photos, hasLength(1));
    expect(merged.photos.first.img, "client-42/ph-1.jpg");

    // Existing home and Plans fields stay intact.
    expect(merged.habits, ["steps"]);
    expect(merged.savedPrograms, hasLength(1));
    expect(merged.nutrition?.trainingTargets.calories, "2100");
  });

  test("failed Plans load retries next time and late home refresh preserves Plans and Log Progress", () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(clientRecordProvider.notifier).update((_) => const ClientRecord(id: "client-99"));

    var attempts = 0;
    await ensureClientSections(
      container,
      "plans",
      clientId: "client-99",
      fetchRecordRows: (columns, {String? profileId}) async {
        attempts++;
        if (attempts == 1) throw Exception("offline");
        return [
          {
            "profile_id": "client-99",
            "savedPrograms": [
              {
                "id": "prog-99",
                "name": "Strength",
                "status": "active",
                "programDays": [
                  {"id": "d1", "title": "Day 1", "exercises": []},
                ],
              },
            ],
          },
        ];
      },
    );
    expect(attempts, 1);
    expect(container.read(clientRecordProvider).savedPrograms, isEmpty);

    await ensureClientSections(
      container,
      "plans",
      clientId: "client-99",
      fetchRecordRows: (columns, {String? profileId}) async {
        attempts++;
        return [
          {
            "profile_id": "client-99",
            "savedPrograms": [
              {
                "id": "prog-99",
                "name": "Strength",
                "status": "active",
                "programDays": [
                  {"id": "d1", "title": "Day 1", "exercises": []},
                ],
              },
            ],
          },
        ];
      },
    );
    expect(attempts, 2);
    expect(container.read(clientRecordProvider).savedPrograms, hasLength(1));

    // Late home-record refresh merges home fields without wiping Plans/Progress.
    final withProgress = container.read(clientRecordProvider).copyWith(
          measurements: const [Measurement(id: "m1", date: "2026-11-24", weight: "150")],
          comms: const [CommMessage(id: "c1", who: "client", text: "Hi", at: "2026-11-24T12:00:00")],
        );
    final homeOnly = SupabaseService.recordsFromDashboardRows([
      {
        "profile_id": "client-99",
        "habitSettings": {"enabled": ["sleep"]},
        "tourSeen": {"dashboard": true},
      },
    ])["client-99"]!;
    final afterHome = withProgress.mergeHomeFrom(homeOnly);
    expect(afterHome.habits, ["sleep"]);
    expect(afterHome.tourSeenDashboard, isTrue);
    expect(afterHome.savedPrograms, hasLength(1));
    expect(afterHome.measurements, hasLength(1));
    expect(afterHome.comms, hasLength(1));
  });
}
