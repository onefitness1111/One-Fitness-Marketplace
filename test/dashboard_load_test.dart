import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/features/auth/signing_in_label.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:supabase_flutter/supabase_flutter.dart" show PostgrestException;

import "package:onefitness/core/supabase/supabase_service.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/data/cache/bootstrap_cache.dart";
import "package:onefitness/core/json/off_main_json.dart";
import "package:onefitness/core/startup/launch_timing.dart";
import "package:onefitness/data/providers/dashboard_load.dart";

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
}
