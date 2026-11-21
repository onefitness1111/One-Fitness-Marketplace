import "dart:async";
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "../../core/auth/web_launch.dart";
import "../../core/images/prefetch_images.dart";
import "../../core/live_log/live_log_sync.dart";
import "../../core/notifications/push_service.dart";
import "../../core/session/login_prompts.dart";
import "../../core/startup/launch_timing.dart";
import "../../core/supabase/supabase_service.dart";
import "../../core/utils/date_utils.dart";
import "../cache/bootstrap_cache.dart";
import "../models/client_info.dart";
import "../models/quiet_nudge.dart";
import "dashboard_extras.dart";
import "dashboard_load.dart";
import "../models/booking.dart";
import "../models/challenge.dart";
import "../models/charge.dart";
import "../models/client_record.dart";
import "../models/comm_message.dart";
import "../models/earned_badge.dart";
import "../models/exercise_def.dart";
import "../models/membership_plan.dart";
import "../models/points_ledger_entry.dart";
import "../models/squad.dart";
import "../models/trainer.dart";
import "../models/waiver_doc.dart";
import "client_providers.dart";
import "platform_settings_provider.dart";
import "role_provider.dart";
import "beep_providers.dart";
import "../../features/trainer/shell/trainer_shell_state.dart";
import "trainer_providers.dart";

/// Runs once at app startup: restores the Supabase Auth session (if any),
/// then defers to [loadAndSeedCoreData] for the actual fetch+seed+restore
/// work — mirrors App.jsx's own "Step 1: core entities" bootstrap effect
/// (loadRoster/loadTrainers/loadBookings, then getSessionProfile-based
/// restore) as closely as possible while every other domain (badges,
/// points, memberships, programs, etc.) still runs on local mock state.
final supabaseBootstrapProvider = FutureProvider<void>((ref) async {
  // Supabase opens secure storage and may refresh a token. That happens
  // after the first frame, so the native splash is only the theme read.
  await SupabaseService.initialize();
  LaunchTiming.phase("supabase ready");
  final uri = ref.read(webLaunchUriProvider);
  if (uri != null && planWebLaunch(uri).kind == WebLaunchKind.setPassword) {
    await consumeWebLaunch(uri);
  }
  await SupabaseService.ensureSession();
  LaunchTiming.markSessionRestored();
  if (SupabaseService.currentUser == null) {
    // Nobody signed in: the only screens reachable are the sign-in and
    // sign-up pages, which need nothing but platform settings (the coach
    // signup's session types). Show them straight away and skip the full
    // load — every sign-in path runs loadAndSeedCoreData itself once the
    // credentials have been checked.
    unawaited(_loadSignedOutBasics(ref));
    LaunchTiming.markDashboardUsable("sign-in screen");
  } else {
    await loadAndSeedCoreData(ref);
  }
  _subscribeRealtimeUpdates(ref);
});

Future<void> _loadSignedOutBasics(Ref ref) async {
  try {
    final settings = await SupabaseService.loadPlatformSettings();
    if (settings != null) ref.read(platformSettingsProvider.notifier).update((_) => settings);
  } catch (e) {
    // The signup form falls back to its defaults; nothing to recover.
    // ignore: avoid_print
    print("[bootstrap] platform settings load failed: $e");
  }
}

AppLifecycleListener? _bookingsLifecycle;
Timer? _bookingsTimer;

/// Live-updates every already-open session (a coach editing exercises
/// while a client is mid-workout-builder, an owner changing a membership
/// plan while a client is on the Membership Hub, a policy change while
/// someone's mid-booking) — mirrors subscribeMembershipPlans/
/// subscribeExercises/subscribePlatformSettings in supabaseData.js. Set up
/// once here (this provider's own body only runs once per app session,
/// unlike loadAndSeedCoreData which reruns on every sign-in) rather than
/// per-screen, so it stays live regardless of which screen is on top.
/// Never explicitly unsubscribed — same as the source, which leaves these
/// live for the whole tab/session.
void _subscribeRealtimeUpdates(Ref ref) {
  // Session-log entries saved on this phone while offline (or left when the app
  // was closed) are sent as soon as the app is up.
  LiveLogOutbox.init();

  SupabaseService.client
      .channel("membership_plans_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "membership_plans",
        callback: (payload) async {
          final plans = await SupabaseService.loadMembershipPlans();
          if (plans.isNotEmpty) ref.read(membershipPlansProvider.notifier).setAll(plans);
        },
      )
      .subscribe();

  SupabaseService.client
      .channel("exercises_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "exercises",
        callback: (payload) async {
          final exercises = await SupabaseService.loadExercises();
          if (exercises.isNotEmpty) ref.read(exerciseCatalogProvider.notifier).setAll(exercises);
        },
      )
      .subscribe();

  // Chat. Re-reads the affected thread rather than patching from the
  // payload, so a message that RLS hides (a blocked user's) never slips in
  // through the realtime path — the select policy is applied on the reread.
  SupabaseService.client
      .channel("messages_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "messages",
        callback: (payload) async {
          final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
          final clientId = row["client_id"] as String?;
          if (clientId == null) return;
          try {
            final thread = await SupabaseService.loadMessagesFor(clientId);
            // Newest first, matching how every chat screen reads `comms`.
            final ordered = thread.reversed.toList();
            ref.read(trainerClientRecordsProvider.notifier).update(
                  clientId,
                  (r) => r.copyWith(comms: ordered),
                );
            // The signed-in client's own copy is a separate provider.
            if (ref.read(clientInfoProvider).id == clientId) {
              ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(comms: ordered));
            }
          } catch (e) {
            // ignore: avoid_print
            print("[realtime messages] reload failed: $e");
          }
        },
      )
      .subscribe();

  SupabaseService.client
      .channel("message_reactions_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "message_reactions",
        callback: (payload) async {
          final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
          final clientId = row["client_id"] as String?;
          if (clientId == null) return;
          try {
            final thread = await SupabaseService.loadMessagesFor(clientId);
            final ordered = thread.reversed.toList();
            ref.read(trainerClientRecordsProvider.notifier).update(
                  clientId,
                  (r) => r.copyWith(comms: ordered),
                );
            if (ref.read(clientInfoProvider).id == clientId) {
              ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(comms: ordered));
            }
          } catch (e) {
            // ignore: avoid_print
            print("[realtime reactions] reload failed: $e");
          }
        },
      )
      .subscribe();

  // A client's saved programs, nutrition plan, intake answers and logs all
  // live on this row. Without this, a program the owner assigned only showed
  // up after the client fully restarted the app.
  SupabaseService.client
      .channel("client_records_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "client_records",
        callback: (payload) async {
          final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
          final profileId = row["profile_id"] as String?;
          if (profileId == null) return;
          try {
            // Re-read rather than trusting the payload, so RLS decides what
            // this user may actually see.
            final record = await SupabaseService.loadClientRecord(profileId);
            // Chat lives in its own table now; keep whatever the messages
            // channel has already put in place rather than blanking it.
            final existingComms =
                ref.read(trainerClientRecordsProvider)[profileId]?.comms ?? const [];
            final merged = record.copyWith(
              comms: record.comms.isEmpty ? existingComms : record.comms,
            );
            ref.read(trainerClientRecordsProvider.notifier).update(profileId, (_) => merged);
            if (ref.read(clientInfoProvider).id == profileId) {
              ref.read(clientRecordProvider.notifier).update((_) => merged);
            }
          } catch (e) {
            // ignore: avoid_print
            print("[realtime client_records] reload failed: $e");
          }
        },
      )
      .subscribe();

  // A client's membership, freeze and cancellation live on their `clients`
  // row. When staff cancel or freeze it, every open app — the client's own
  // and other staff — picks the change up here. Only delivers once `clients`
  // is in the supabase_realtime publication; until then the on-resume
  // refresh (refreshClientInfos) covers it.
  SupabaseService.client
      .channel("clients_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "clients",
        callback: (payload) async {
          final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
          final id = row["profile_id"] as String?;
          if (id == null) return;
          try {
            await refreshClientInfos(ref, onlyId: id);
          } catch (e) {
            // ignore: avoid_print
            print("[realtime clients] reload failed: $e");
          }
        },
      )
      .subscribe();

  // Merit Badges are otherwise fetched once, at bootstrap. The ONE Fitness
  // badge is awarded the instant a plan is bought (migration 18's trigger
  // on clients.membership_plan_id), so without this a client who just
  // bought a membership would see no badge until they next restarted the
  // app — indistinguishable, from their side, from it not being awarded at
  // all. The same applies to a coach awarding a PR badge while the client
  // is looking at their gallery.
  SupabaseService.client
      .channel("merit_badges_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "merit_badges",
        callback: (payload) async {
          final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
          final clientId = row["client_id"] as String?;
          if (clientId == null) return;
          try {
            // Re-fetch rather than patch from the payload: RLS decides what
            // this viewer may see, and a revoke arrives as an update whose
            // old row is the one worth replacing.
            final fresh = await SupabaseService.loadMeritBadgesFor(clientId);
            ref.read(earnedBadgesProvider.notifier).replaceForClient(clientId, fresh);
          } catch (e) {
            // ignore: avoid_print
            print("[realtime merit_badges] reload failed: $e");
          }
        },
      )
      .subscribe();

  SupabaseService.client
      .channel("platform_settings_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "platform_settings",
        callback: (payload) async {
          final settings = await SupabaseService.loadPlatformSettings();
          if (settings != null) ref.read(platformSettingsProvider.notifier).update((_) => settings);
        },
      )
      .subscribe();

  // Bookings. Loaded once at sign-in otherwise, so a booking or cancellation
  // made on one device never reached the other. Every insert, update and
  // delete is mirrored into both booking providers; a cancellation (a delete,
  // or a row stamped cancelled_at) leaves both sides.
  SupabaseService.client
      .channel("bookings_live")
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: "public",
        table: "bookings",
        callback: (payload) {
          try {
            final all = ref.read(allBookingsProvider.notifier);
            final mine = ref.read(clientBookingsProvider.notifier);
            if (payload.eventType == PostgresChangeEvent.delete) {
              final id = payload.oldRecord["id"]?.toString();
              if (id == null) return;
              all.cancelBooking(id);
              mine.cancelBooking(id);
              return;
            }
            final row = payload.newRecord;
            if (row.isEmpty) return;
            final id = row["id"]?.toString();
            if (id == null) return;
            if (row["cancelled_at"] != null) {
              all.cancelBooking(id);
              mine.cancelBooking(id);
              return;
            }
            final booking = SupabaseService.bookingFromRealtimeRow(row);
            if (booking == null) return;
            all.upsert(booking);
            if (ref.read(clientSignedInProvider) == true &&
                booking.clientId == ref.read(clientInfoProvider).id) {
              mine.upsert(booking);
            }
          } catch (e) {
            // ignore: avoid_print
            print("[realtime bookings] apply failed: $e");
          }
        },
      )
      .subscribe();

  // Safety net for the live feed above. A phone that was asleep or lost its
  // connection can silently miss the "checked in" update, which left a client's
  // calendar showing a missed (red) or upcoming (white) day for a session the
  // coach had already checked them in to. So the bookings are also re-read when
  // the app comes back to the foreground and every little while it's open; a
  // client's own list is small, so theirs refreshes most often.
  Future<void> refreshBookings() async {
    try {
      if (SupabaseService.currentUser == null) return;
      final bookings = _fullBookingsLoaded
          ? await SupabaseService.loadBookings()
          : await SupabaseService.loadDashboardBookings();
      ref.read(allBookingsProvider.notifier).setAll(bookings);
      if (ref.read(clientSignedInProvider) == true) {
        final id = ref.read(clientInfoProvider).id;
        ref.read(clientBookingsProvider.notifier).setAll(bookings.where((b) => b.clientId == id).toList());
      }
    } catch (_) {
      // Next tick tries again.
    }
  }

  _bookingsLifecycle?.dispose();
  _bookingsLifecycle = AppLifecycleListener(onResume: refreshBookings);
  _bookingsTimer?.cancel();
  var bookingsTick = 0;
  _bookingsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    bookingsTick++;
    final isClient = ref.read(clientSignedInProvider) == true;
    // Staff load the whole gym's bookings, so they refresh every 2 minutes.
    if (isClient || bookingsTick % 4 == 0) refreshBookings();
  });

  // Live sessions and Beep Your Coach. These have their own subscriber
  // because they carry state as well as a stream — which session is running,
  // and which beeps are still outstanding — and because the coach's alert
  // has to fire the moment a row lands, not on the next screen build.
  unawaited(ref.read(beepRealtimeProvider).start());
}


/// Fetches what the first screen needs and paints it, then loads the rest.
///
/// Called by the startup bootstrap above when a session already exists, and
/// right after every successful sign-in in client_auth_screen.dart /
/// trainer_auth_screen.dart / the signup screens.
///
/// A saved snapshot for this user paints the whole first screen at once,
/// then a refresh replaces it. Sign-out deletes that snapshot. A different
/// account never reads it: the key is the user id, and signing in as
/// someone else drops the previous person's copy.
///
/// The sign-in button returns when the greeting, the booking window, and
/// the plan list are in. Habit logs, programs, contacts, billing, push, and
/// the on-device snapshot do not hold that up. A warm open skips the
/// network entirely until the saved screen is on display.
///
/// Takes `dynamic` rather than `Ref` on purpose: Riverpod's `Ref` (used by
/// providers) and `WidgetRef` (used by widgets, e.g. a ConsumerState's
/// `ref`) are deliberately unrelated types with no common supertype, but
/// both expose the same `.read<T>(provider)` — this needs to be callable
/// from both a FutureProvider body and a sign-in screen's widget state.
/// The background phase must not touch `ref` itself: a sign-in screen is
/// disposed as soon as the shell replaces it, and its WidgetRef dies with
/// it. It works through notifiers read up front instead, which live on in
/// the ProviderScope.
///
/// [roleGate] is the role read started by the sign-in button, so it overlaps
/// the first data round instead of sitting in front of it. When it disagrees
/// with [knownRole] the session is cleared and the button shows the error.
Future<void> loadAndSeedCoreData(
  dynamic ref, {
  String? knownRole,
  Future<String?>? roleGate,
}) async {
  _installSignOutHook();
  final generation = ++_loadGeneration;
  _payGeneration = -1;
  _resetSections(generation);
  final hold = _Hold.read(ref);
  hold.markPay(false);
  final showing = _shellVisible(ref);
  if (!showing) hold.details.set(false);

  String? userId;
  try {
    userId = SupabaseService.currentUser?.id;
  } catch (_) {}

  final window = dashboardBookingWindow(DateTime.now());
  // These three are the same for every role and do not need the directory.
  // Starting them before the cache decode and the role read is what keeps
  // a cold open from paying those one after another.
  final bookingF = _timed(
    "bookings",
    SupabaseService.fetchBookingRows(from: window.from, to: window.to),
    <Map<String, dynamic>>[],
  );
  final planF = _timed("plans", SupabaseService.fetchPlanRows(), <Map<String, dynamic>>[]);
  final settingsF = _timed("settings", SupabaseService.fetchSettingsJson(), null);
  final waiverF = _timed("waivers", SupabaseService.fetchWaiverRows(), <Map<String, dynamic>>[]);

  final cached = userId == null ? null : await _cachedScreen(userId);
  if (generation != _loadGeneration) return;
  if (cached != null) {
    LoginPrompts.finishDashboardLoad();
    hold.details.set(true);
    _paint(
      hold,
      cached.profile,
      cached.roster,
      cached.trainers,
      cached.bookings,
      cached.records,
      cached.plans,
      cached.waivers,
      cached.settings,
      keepPay: false,
    );
    if (cached.payReady) hold.markPay(true);
    _applyExtras(hold, cached.extras);
    final ownId = _restoreSession(
      hold,
      cached.profile,
      cached.roster,
      cached.trainers,
      cached.bookings,
      cached.records,
    );
    if (ownId == _signedOut) return;
    LaunchTiming.markDashboardUsable("cached dashboard");
    LaunchQueryLog.note("warm open from cache for $userId; refresh in the background");
    final cachedRole = cached.profile?["role"] as String?;
    unawaited(_openForRole(
      hold: hold,
      generation: generation,
      userId: userId,
      role: cachedRole,
      clearSamples: false,
      bookingF: bookingF,
      planF: planF,
      settingsF: settingsF,
      waiverF: waiverF,
    ));
    return;
  }

  final expected = knownRole;
  Future<List<Map<String, dynamic>>>? clientF;
  Future<List<Map<String, dynamic>>>? homeRecordF;
  Future<List<Map<String, dynamic>>>? directoryF;
  // A cold open does not know the role yet. The client row is one small
  // read, so it starts anyway and overlaps the role call. A staff sign-in
  // already knows, and starts the directory instead.
  if (userId != null && expected != "coach" && expected != "owner") {
    clientF = _timed(
      "client-row",
      SupabaseService.fetchClientRows([userId], includeBilling: false),
      <Map<String, dynamic>>[],
    );
    homeRecordF = _timed(
      "home-record",
      SupabaseService.fetchRecordRowsOffMain(clientHomeRecordColumns, profileId: userId),
      <Map<String, dynamic>>[],
    );
  } else if (expected == "coach" || expected == "owner") {
    directoryF = _timed("directory", _directory(), <Map<String, dynamic>>[], fatal: true);
  }

  final role = await (roleGate ?? Future<String?>.value(expected ?? await SupabaseService.currentRole()));
  if (generation != _loadGeneration) return;
  if (knownRole != null && role != knownRole) {
    _loadGeneration++;
    await SupabaseService.signOut();
    throw Exception(_wrongRoleMessage(knownRole));
  }
  LaunchTiming.phase("role ${role ?? "none"}");
  if (knownRole != null) LaunchQueryLog.note("signed in as $knownRole");

  await _openForRole(
    hold: hold,
    generation: generation,
    userId: userId,
    role: role,
    clearSamples: true,
    bookingF: bookingF,
    planF: planF,
    settingsF: settingsF,
    waiverF: waiverF,
    clientF: clientF,
    homeRecordF: homeRecordF,
    directoryF: directoryF,
  );
}

String _wrongRoleMessage(String role) {
  if (role == "client") return "This account isn't set up as a client.";
  if (role == "owner") return "This account isn't the owner account.";
  return "This account isn't set up as a coach.";
}

bool _shellVisible(dynamic ref) {
  try {
    if (ref.read(clientSignedInProvider) == true) return true;
    if (ref.read(trainerAuthProvider) != null) return true;
  } catch (_) {}
  return false;
}

Future<CachedFirstScreen?> _cachedScreen(String userId) async {
  await BootstrapCache.activate(userId);
  final json = await BootstrapCache.read(userId);
  if (json == null) return null;
  return SupabaseService.decodeFirstScreen(json);
}

Future<List<Map<String, dynamic>>> _directory() async {
  try {
    return await SupabaseService.loadProfileDirectoryOffMain();
  } catch (e) {
    LaunchQueryLog.note("directory off-main failed, using the client library: $e");
    return SupabaseService.loadProfileDirectory();
  }
}

Future<void> _openForRole({
  required _Hold hold,
  required int generation,
  required String? userId,
  required String? role,
  required bool clearSamples,
  required Future<List<Map<String, dynamic>>> bookingF,
  required Future<List<Map<String, dynamic>>> planF,
  required Future<Map<String, dynamic>?> settingsF,
  required Future<List<Map<String, dynamic>>> waiverF,
  Future<List<Map<String, dynamic>>>? clientF,
  Future<List<Map<String, dynamic>>>? homeRecordF,
  Future<List<Map<String, dynamic>>>? directoryF,
}) async {
  if (role == "client" && userId != null) {
    await _openClient(
      hold: hold,
      generation: generation,
      me: userId,
      clearSamples: clearSamples,
      bookingF: bookingF,
      planF: planF,
      settingsF: settingsF,
      waiverF: waiverF,
      clientF: clientF,
      homeRecordF: homeRecordF,
    );
    return;
  }
  if (role == "coach" || role == "owner") {
    await _openStaff(
      hold: hold,
      generation: generation,
      userId: userId,
      clearSamples: clearSamples,
      bookingF: bookingF,
      planF: planF,
      settingsF: settingsF,
      waiverF: waiverF,
      directoryF: directoryF,
    );
    return;
  }
  LoginPrompts.finishDashboardLoad();
  LaunchTiming.markDashboardUsable("no profile");
}

Future<void> _openClient({
  required _Hold hold,
  required int generation,
  required String me,
  required bool clearSamples,
  required Future<List<Map<String, dynamic>>> bookingF,
  required Future<List<Map<String, dynamic>>> planF,
  required Future<Map<String, dynamic>?> settingsF,
  required Future<List<Map<String, dynamic>>> waiverF,
  Future<List<Map<String, dynamic>>>? clientF,
  Future<List<Map<String, dynamic>>>? homeRecordF,
}) async {
  clientF ??= _timed(
    "client-row",
    SupabaseService.fetchClientRows([me], includeBilling: false),
    <Map<String, dynamic>>[],
  );
  homeRecordF ??= _timed(
    "home-record",
    SupabaseService.fetchRecordRowsOffMain(clientHomeRecordColumns, profileId: me),
    <Map<String, dynamic>>[],
  );
  final clientRows = await clientF;
  final bookingRows = await bookingF;
  final planRows = await planF;
  if (generation != _loadGeneration) return;
  final homeRows = await _ifReady(homeRecordF);
  final profile = SupabaseService.provisionalProfile(role: "client");
  final roster = SupabaseService.rosterFromParts([profile], clientRows);
  final bookings = SupabaseService.bookingsFromRows(bookingRows);
  final plans = SupabaseService.plansFromRows(planRows);
  final records = homeRows == null ? <String, ClientRecord>{} : SupabaseService.recordsFromDashboardRows(homeRows);
  if (clearSamples) _clearSamples(hold);
  _paint(
    hold,
    profile,
    roster,
    const [],
    bookings,
    records,
    plans,
    const [],
    null,
    keepPay: hold.payReady,
    replaceTrainers: clearSamples,
    replaceRecords: records.isNotEmpty || clearSamples,
    replaceWaivers: clearSamples,
  );
  if (homeRows != null) hold.details.set(true);
  if (clearSamples) {
    final ownId = _restoreSession(hold, profile, roster, const [], bookings, records);
    if (ownId == _signedOut) return;
  }
  LoginPrompts.finishDashboardLoad();
  LaunchTiming.markDashboardUsable("client home");
  LaunchQueryLog.note("client home painted; rounds=${blockingSignInRounds("client")}");
  _rememberScreen(
    userId: me,
    directory: [profile],
    clientRows: clientRows,
    trainerRows: const [],
    bookingRows: bookingRows,
    recordRows: const [],
    ownRecord: homeRows == null || homeRows.isEmpty ? null : _recordPayload(homeRows.first),
    planRows: planRows,
    waiverRows: const [],
    settings: null,
    isClient: true,
  );
  _applyWhenReady(hold, generation, settingsF, waiverF);
  if (homeRows == null) {
    unawaited(homeRecordF.then((rows) {
      if (generation != _loadGeneration) return;
      final record = SupabaseService.recordsFromDashboardRows(rows)[me];
      if (record != null) {
        hold.ownRecord.update((_) => record);
        hold.records.setAll({me: record});
        _rememberScreen(
          userId: me,
          directory: [profile],
          clientRows: clientRows,
          trainerRows: const [],
          bookingRows: bookingRows,
          recordRows: const [],
          ownRecord: rows.isEmpty ? null : _recordPayload(rows.first),
          planRows: planRows,
          waiverRows: const [],
          settings: null,
          isClient: true,
        );
      }
      hold.details.set(true);
    }));
  }
  unawaited(_clientBehind(hold, generation, me, profile, clientRows, bookings));
  _loadExtras(hold, generation, me);
  unawaited(prefetchNetworkImages(_aboveFoldPhotos(
    profile: profile,
    roster: roster,
    trainers: const [],
    bookings: bookings,
  )));
}

Future<void> _openStaff({
  required _Hold hold,
  required int generation,
  required String? userId,
  required bool clearSamples,
  required Future<List<Map<String, dynamic>>> bookingF,
  required Future<List<Map<String, dynamic>>> planF,
  required Future<Map<String, dynamic>?> settingsF,
  required Future<List<Map<String, dynamic>>> waiverF,
  Future<List<Map<String, dynamic>>>? directoryF,
}) async {
  directoryF ??= _timed("directory", _directory(), <Map<String, dynamic>>[], fatal: true);
  final directory = await directoryF;
  if (generation != _loadGeneration) return;
  final profile = SupabaseService.sessionProfileIn(directory);
  final clientIds = [
    for (final p in directory)
      if (p["role"] == "client" && p["id"] is String) p["id"] as String,
  ];
  final coachIds = [
    for (final p in directory)
      if (p["role"] == "coach" && p["id"] is String) p["id"] as String,
  ];
  // Bookings and plans have been in flight since the directory started.
  final rows = await Future.wait<List<Map<String, dynamic>>>([
    _timed(
      "client-rows",
      SupabaseService.fetchClientRows(clientIds, includeBilling: false),
      <Map<String, dynamic>>[],
    ),
    _timed(
      "trainer-rows",
      SupabaseService.fetchTrainerRows(coachIds, columns: dashboardTrainerColumns),
      <Map<String, dynamic>>[],
    ),
  ]);
  final bookingRows = await bookingF;
  final planRows = await planF;
  final settingsJson = await settingsF;
  if (generation != _loadGeneration) return;
  final clientRows = rows[0];
  final trainerRows = rows[1];
  final roster = SupabaseService.rosterFromParts(directory, clientRows);
  final trainers = SupabaseService.trainersFromParts(directory, trainerRows);
  final bookings = SupabaseService.bookingsFromRows(bookingRows);
  final plans = SupabaseService.plansFromRows(planRows);
  final settings = SupabaseService.settingsFromJson(settingsJson);
  if (clearSamples) _clearSamples(hold);
  _paint(
    hold,
    profile,
    roster,
    trainers,
    bookings,
    const {},
    plans,
    const [],
    settings,
    keepPay: hold.payReady,
    replaceRecords: clearSamples,
    replaceWaivers: clearSamples,
  );
  if (clearSamples) {
    final ownId = _restoreSession(hold, profile, roster, trainers, bookings, const {});
    if (ownId == _signedOut) return;
  }
  LoginPrompts.finishDashboardLoad();
  LaunchTiming.markDashboardUsable("staff home");
  LaunchQueryLog.note("staff home painted; rounds=${blockingSignInRounds(profile?["role"] as String? ?? "coach")}");
  _applyWhenReady(hold, generation, settingsF, waiverF);
  _rememberScreen(
    userId: userId,
    directory: directory,
    clientRows: clientRows,
    trainerRows: trainerRows,
    bookingRows: bookingRows,
    recordRows: const [],
    ownRecord: null,
    planRows: planRows,
    waiverRows: const [],
    settings: settingsJson,
    isClient: false,
  );
  unawaited(_staffBehind(hold, generation, userId, directory, clientRows, trainerRows, bookingRows, planRows, settingsJson, roster, trainers, bookings));
  _loadExtras(hold, generation, userId);
  // The owner used to download the rest of the gym before the home screen
  // could open. It still starts now, after the schedule is visible.
  if (profile?["role"] == "owner") {
    unawaited(_loadPay(hold, generation));
    _startDeferred(hold, generation, null);
  }
  unawaited(prefetchNetworkImages(_aboveFoldPhotos(
    profile: profile,
    roster: roster,
    trainers: trainers,
    bookings: bookings,
  )));
}

void _applyWhenReady(
  _Hold hold,
  int generation,
  Future<Map<String, dynamic>?> settingsF,
  Future<List<Map<String, dynamic>>> waiverF,
) {
  unawaited(settingsF.then((row) {
    if (generation != _loadGeneration) return;
    final settings = SupabaseService.settingsFromJson(row);
    if (settings != null) hold.settings.update((_) => settings);
  }));
  unawaited(waiverF.then((rows) {
    if (generation != _loadGeneration) return;
    hold.waivers.setAll(SupabaseService.waiversFromRows(rows));
    _sectionInflight[GymSection.waivers] = Future<void>.value();
  }));
}

Future<void> _clientBehind(
  _Hold hold,
  int generation,
  String me,
  Map<String, dynamic> profile,
  List<Map<String, dynamic>> clientRows,
  List<Booking> bookings,
) async {
  try {
    final directory = await _timed("directory", _directory(), <Map<String, dynamic>>[]);
    if (generation != _loadGeneration || directory.isEmpty) return;
    Map<String, dynamic>? self;
    for (final p in directory) {
      if (p["id"] == me) self = p;
    }
    final merged = <String, dynamic>{...profile, ...?self};
    await SupabaseService.attachContacts([merged]);
    if (generation != _loadGeneration) return;
    await SupabaseService.attachBilling(clientRows);
    if (generation != _loadGeneration) return;
    final roster = SupabaseService.rosterFromParts([merged], clientRows);
    hold.roster.setAll(roster);
    if (roster.isNotEmpty) hold.info.update((_) => roster.first);
    final coachIds = [
      for (final p in directory)
        if (p["role"] == "coach" && p["id"] is String) p["id"] as String,
    ];
    final trainerRows = await _timed(
      "trainer-rows",
      SupabaseService.fetchTrainerRows(coachIds, columns: dashboardTrainerColumns),
      <Map<String, dynamic>>[],
    );
    if (generation != _loadGeneration) return;
    final trainers = SupabaseService.trainersFromParts(directory, trainerRows);
    hold.trainers.setAll(trainers);
    unawaited(prefetchNetworkImages(_aboveFoldPhotos(
      profile: merged,
      roster: roster,
      trainers: trainers,
      bookings: bookings,
    )));
  } catch (e) {
    // ignore: avoid_print
    print("[loadAndSeedCoreData] client background failed: $e");
  }
}

Future<void> _staffBehind(
  _Hold hold,
  int generation,
  String? userId,
  List<Map<String, dynamic>> directory,
  List<Map<String, dynamic>> clientRows,
  List<Map<String, dynamic>> trainerRows,
  List<Map<String, dynamic>> bookingRows,
  List<Map<String, dynamic>> planRows,
  Map<String, dynamic>? settingsJson,
  List<ClientInfo> roster,
  List<Trainer> trainers,
  List<Booking> bookings,
) async {
  try {
    final copies = [for (final p in directory) Map<String, dynamic>.from(p)];
    await SupabaseService.attachContacts(copies);
    if (generation != _loadGeneration) return;
    await SupabaseService.attachBilling(clientRows);
    if (generation != _loadGeneration) return;
    final nextRoster = SupabaseService.rosterFromParts(copies, clientRows);
    hold.roster.setAll(nextRoster);
    final recordRows = await _timed(
      "program-records",
      SupabaseService.fetchRecordRowsOffMain(staffDetailRecordColumns),
      <Map<String, dynamic>>[],
    );
    if (generation != _loadGeneration) return;
    final records = SupabaseService.recordsFromDashboardRows(recordRows);
    hold.records.setAll(records);
    hold.details.set(true);
    _rememberScreen(
      userId: userId,
      directory: copies,
      clientRows: clientRows,
      trainerRows: trainerRows,
      bookingRows: bookingRows,
      recordRows: recordRows,
      ownRecord: null,
      planRows: planRows,
      waiverRows: const [],
      settings: settingsJson,
      isClient: false,
    );
    unawaited(prefetchNetworkImages(_aboveFoldPhotos(
      profile: SupabaseService.sessionProfileIn(copies),
      roster: nextRoster,
      trainers: trainers,
      bookings: bookings,
    )));
  } catch (e) {
    if (generation == _loadGeneration) hold.details.set(true);
    // ignore: avoid_print
    print("[loadAndSeedCoreData] staff background failed: $e");
  }
}

void _loadExtras(_Hold hold, int generation, String? me) {
  unawaited(_timed("renewals", SupabaseService.syncPackageRenewals(), <Map<String, dynamic>>[]).then((rows) {
    _patchExtras(hold, generation, (e) => e.copyWith(renewals: rows));
  }));
  unawaited(_timed("quiet-nudges", SupabaseService.loadQuietNudges(), <QuietNudge>[]).then((nudges) {
    _patchExtras(hold, generation, (e) => e.copyWith(nudges: nudges));
  }));
  unawaited(_timed("live-days", LiveActivity.openDays(), <String, String>{}).then((days) {
    _patchExtras(hold, generation, (e) => e.copyWith(liveDays: days));
  }));
  unawaited(_timed("charges", SupabaseService.loadCharges(), <Charge>[]).then((charges) {
    if (generation != _loadGeneration) return;
    hold.charges.setAll(charges);
    _sectionInflight[GymSection.charges] = Future<void>.value();
  }));
  if (me == null) return;
  unawaited(_timed("badges", SupabaseService.loadMeritBadgesFor(me), <EarnedBadge>[]).then((badges) {
    if (generation != _loadGeneration) return;
    hold.badges.setAll(badges);
    _sectionInflight[GymSection.badges] = Future<void>.value();
  }));
  unawaited(_timed("balance", SupabaseService.loadBalanceCents(me), 0).then((cents) {
    _patchExtras(
      hold,
      generation,
      (e) => e.copyWith(balanceCents: cents < 0 ? cents : null, clearBalance: cents >= 0),
    );
  }));
}

void _patchExtras(_Hold hold, int generation, DashboardExtras Function(DashboardExtras current) change) {
  if (generation != _loadGeneration) return;
  hold.extras.update(change);
}

/// Resolves with [future]'s value when it has already finished, otherwise
/// null so the caller can paint and apply the value later.
Future<T?> _ifReady<T>(Future<T> future) {
  final finished = Completer<T?>();
  future.then(finished.complete, onError: (_) {
    if (!finished.isCompleted) finished.complete(null);
  });
  return Future.any<T?>([
    finished.future,
    Future<T?>.delayed(Duration.zero, () => null),
  ]);
}

Map<String, dynamic> _recordPayload(Map<String, dynamic> row) {
  dynamic pick(String key) => row[key] ?? row["data->$key"];
  return {
    "habitSettings": pick("habitSettings"),
    "habitLogs": pick("habitLogs"),
    "tourSeen": pick("tourSeen"),
    "intake": pick("intake"),
    "signatures": pick("signatures"),
    "workoutLogs": pick("workoutLogs"),
    "logs": pick("logs"),
    "savedPrograms": pick("savedPrograms"),
    "nutrition": pick("nutrition"),
    "trainerNotes": pick("trainerNotes"),
    "programRefresh": pick("programRefresh"),
  };
}

void _rememberScreen({
  required String? userId,
  required List<Map<String, dynamic>> directory,
  required List<Map<String, dynamic>> clientRows,
  required List<Map<String, dynamic>> trainerRows,
  required List<Map<String, dynamic>> bookingRows,
  required List<Map<String, dynamic>> recordRows,
  required Map<String, dynamic>? ownRecord,
  required List<Map<String, dynamic>> planRows,
  required List<Map<String, dynamic>> waiverRows,
  required Map<String, dynamic>? settings,
  required bool isClient,
}) {
  _saveSnapshot(userId, () {
    final payload = SupabaseService.encodeFirstScreen(
      directory: directory,
      clientRows: clientRows,
      trainerRows: trainerRows,
      bookingRows: bookingRows,
      recordRows: recordRows,
      ownRecord: ownRecord,
      planRows: planRows,
      waiverRows: waiverRows,
      settings: settings,
      payRows: _pendingPayload?["payRows"] is List ? SupabaseService.payRowsFrom(_pendingPayload!["payRows"]) : null,
      isClient: isClient,
    );
    final extras = _pendingPayload?["extras"];
    if (extras is Map) payload["extras"] = extras;
    return payload;
  });
}

const _signedOut = "__signed_out__";

Map<String, dynamic>? _pendingPayload;
String? _pendingUser;

Future<T> _timed<T>(String name, Future<T> future, T fallback, {bool fatal = false}) {
  final sw = Stopwatch()..start();
  return future.then((value) {
    LaunchQueryLog.note("$name ${sw.elapsedMilliseconds}ms");
    LaunchTiming.phase("$name ${sw.elapsedMilliseconds}ms");
    return value;
  }).catchError((Object e) {
    LaunchQueryLog.note("$name failed ${sw.elapsedMilliseconds}ms: $e");
    LaunchTiming.phase("$name failed ${sw.elapsedMilliseconds}ms");
    if (fatal) throw e;
    return fallback;
  });
}

Map<String, String> _liveDaysFrom(Object? raw) {
  final out = <String, String>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      final day = entry.value?.toString() ?? "";
      if (day.isNotEmpty) out[entry.key.toString()] = day;
    }
  } else if (raw is List) {
    for (final row in raw) {
      if (row is! Map) continue;
      final id = row["client_id"]?.toString() ?? "";
      final day = row["day_id"]?.toString() ?? "";
      if (id.isNotEmpty && day.isNotEmpty) out[id] = day;
    }
  }
  return out;
}

List<String?> _aboveFoldPhotos({
  required Map<String, dynamic>? profile,
  required List<ClientInfo> roster,
  required List<Trainer> trainers,
  required List<Booking> bookings,
}) {
  final today = isoDate(DateTime.now());
  final urls = <String?>[profile?["photo_url"] as String?];
  final people = {for (final c in roster) c.id: c.photo};
  final coaches = {for (final t in trainers) t.id: t.photo};
  for (final b in bookings.where((b) => b.date == today)) {
    urls.add(people[b.clientId]);
    urls.add(coaches[b.trainerId]);
  }
  return urls;
}

void _applyExtras(_Hold hold, Map<String, dynamic> extras) {
  if (extras.containsKey("badges")) {
    hold.badges.setAll(SupabaseService.badgesFromRows(SupabaseService.asRowList(extras["badges"])));
    _sectionInflight[GymSection.badges] = Future<void>.value();
  }
  if (extras.containsKey("charges")) {
    hold.charges.setAll(SupabaseService.chargesFromRows(SupabaseService.asRowList(extras["charges"])));
    _sectionInflight[GymSection.charges] = Future<void>.value();
  }
  final nudges = [
    for (final row in SupabaseService.asRowList(extras["quietNudges"]))
      if (QuietNudge.fromJson(row) != null) QuietNudge.fromJson(row)!,
  ];
  final balance = extras["balanceCents"];
  hold.extras.replace(DashboardExtras(
    balanceCents: balance is num && balance < 0 ? balance.toInt() : null,
    renewals: SupabaseService.asRowList(extras["renewals"]),
    liveDays: _liveDaysFrom(extras["liveDays"]),
    nudges: nudges,
  ));
}

/// Encodes and writes the snapshot after the dashboard has a chance to
/// paint. The disk write used to finish before the shell was allowed up.
void _saveSnapshot(String? userId, Map<String, dynamic> Function() build) {
  if (userId == null) return;
  unawaited(Future<void>(() async {
    try {
      final payload = build();
      _pendingPayload = payload;
      _pendingUser = userId;
      await BootstrapCache.write(userId, payload);
    } catch (e) {
      // ignore: avoid_print
      print("[bootstrap] snapshot save failed: $e");
    }
  }));
}

void _paint(
  _Hold hold,
  Map<String, dynamic>? profile,
  List<ClientInfo> roster,
  List<Trainer> trainers,
  List<Booking> bookings,
  Map<String, ClientRecord> records,
  List<MembershipPlan> plans,
  List<WaiverDoc> waivers,
  PlatformSettings? settings, {
  required bool keepPay,
  bool replaceTrainers = true,
  bool replaceRecords = true,
  bool replaceWaivers = true,
}) {
  var next = trainers;
  if (keepPay && hold.pay.ready) {
    final previous = {for (final t in hold.trainers.snapshot()) t.id: t};
    next = [
      for (final t in trainers)
        if (previous[t.id] == null) t else t.withPayFrom(previous[t.id]!),
    ];
  }
  hold.paintedTrainers = next;
  hold.roster.setAll(roster);
  if (replaceTrainers) hold.trainers.setAll(next);
  hold.bookings.setAll(bookings);
  // Server lists replace the built-in sample, including an empty list.
  hold.plans.setAll(plans);
  if (replaceWaivers) hold.waivers.setAll(waivers);
  if (settings != null) hold.settings.update((_) => settings);
  if (replaceRecords) hold.records.setAll(records);
  // profile is restored by the caller; kept in the signature so a paint
  // always travels with the person it belongs to.
  assert(profile == null || profile["id"] != null);
}

/// Returns the signed-in client id, null for staff, or [_signedOut].
String? _restoreSession(
  _Hold hold,
  Map<String, dynamic>? profile,
  List<ClientInfo> roster,
  List<Trainer> trainers,
  List<Booking> bookings,
  Map<String, ClientRecord> records,
) {
  if (profile == null) return null;
  final role = profile["role"] as String?;
  final id = profile["id"] as String;
  if (role == "owner") {
    hold.role.set("trainer");
    hold.auth.signIn("owner");
  } else if (role == "coach" && trainers.any((t) => t.id == id)) {
    hold.role.set("trainer");
    hold.auth.signIn(id);
  } else if (role == "coach") {
    unawaited(SupabaseService.signOut());
    return _signedOut;
  } else if (role == "client") {
    final matches = roster.where((c) => c.id == id);
    if (matches.isEmpty) {
      unawaited(SupabaseService.signOut());
      return _signedOut;
    }
    hold.role.set("client");
    hold.ownClientId = id;
    hold.info.update((_) => matches.first);
    hold.ownRecord.update((_) => records[id] ?? const ClientRecord(id: ""));
    hold.clientBookings.setAll(bookings.where((b) => b.clientId == id).toList());
    hold.signedIn.signIn();
    _armPush(hold, prompt: false);
    LoginPrompts.arm();
    return id;
  }
  if (role == "owner" || role == "coach") _armPush(hold, prompt: role == "owner");
  if (role == "coach") LoginPrompts.arm();
  return null;
}

bool _pushPrompted = false;

void _armPush(_Hold hold, {required bool prompt}) {
  unawaited(PushService.attachHandlers());
  if (prompt && !_pushPrompted) {
    _pushPrompted = true;
    unawaited(PushService.registerForCurrentUser());
  }
  PushService.onOpenRoute = (data) {
    if (data["type"] == "beep") hold.mode.go("dashboard");
  };
}

void _clearSamples(_Hold hold) {
  hold.points.setAll(const <PointsLedgerEntry>[]);
  hold.badges.setAll(const <EarnedBadge>[]);
  hold.challenges.setAll(const <Challenge>[]);
  hold.charges.setAll(const <Charge>[]);
}

void _startDeferred(_Hold hold, int generation, String? ownClientId) {
  void later<T>(Future<T> f, String what, void Function(T) apply) {
    unawaited(f.then((v) {
      if (generation == _loadGeneration) apply(v);
    }).catchError((Object e) {
      // ignore: avoid_print
      print("[loadAndSeedCoreData] $what load failed: $e");
    }));
  }

  later(SupabaseService.loadPointsLedgerAll(), "points", hold.points.setAll);
  later(SupabaseService.loadMeritBadgesAll(), "badges", hold.badges.setAll);
  later(SupabaseService.loadChallenges(), "challenges", hold.challenges.setAll);
  later(SupabaseService.loadChallengeTemplates(), "challenge_templates", hold.templates.setAll);
  later(SupabaseService.loadCharges(), "charges", hold.charges.setAll);
  later(SupabaseService.loadBlockedTime(), "blocked time", hold.blocked.setAll);
  later(SupabaseService.loadProducts(), "products", hold.products.setAll);
  later(SupabaseService.loadCoupons(), "coupons", hold.coupons.setAll);
  later(SupabaseService.loadProgramsLibrary(), "programs", hold.programs.setAll);
  later(SupabaseService.loadNutritionLibrary(), "nutrition", hold.nutrition.setAll);
  later(SupabaseService.loadCustomMeals(), "custom meals", hold.meals.setAll);
  later(SupabaseService.loadExercises(), "exercises", (List<ExerciseDef> v) {
    if (v.isNotEmpty) hold.exercises.setAll(v);
  });
  later(SupabaseService.loadSquads(), "squads", hold.squads.setAll);
  later(SupabaseService.loadWaitlist(), "waitlist", hold.waitlist.setAll);
  later(SupabaseService.loadPackageCategories(), "package categories", hold.categories.setAll);
  later(SupabaseService.loadEquipment(), "equipment", hold.equipment.setAll);
  later(SupabaseService.loadIntakeFormTemplates(), "intake forms", hold.forms.setAll);
  later(SupabaseService.loadCoachMeritBadges(), "coach badges", hold.coachBadges.setAll);
  later(SupabaseService.loadCoachPrEvents(), "coach PR events", hold.prEvents.setAll);
  final own = ownClientId;
  later(SupabaseService.loadAllMessages(), "messages", (Map<String, List<CommMessage>> byClient) {
    hold.records.mergeComms(byClient);
    final thread = own == null ? null : byClient[own];
    if (thread != null) {
      hold.ownRecord.update((r) {
        final byId = {for (final m in r.comms) m.id: m, for (final m in thread) m.id: m};
        return r.copyWith(comms: byId.values.toList()..sort((a, b) => b.sentAt.compareTo(a.sentAt)));
      });
    }
  });
}

final Map<GymSection, Future<void>> _sectionInflight = {};
bool _fullBookingsLoaded = false;
final Map<String, Future<void>> _fullRecords = {};

void _installSignOutHook() {
  SupabaseService.afterSignOut ??= () {
    LoginPrompts.reset();
    _pushPrompted = false;
    _sectionInflight.clear();
    _fullRecords.clear();
    _fullBookingsLoaded = false;
  };
}

void _resetSections(int generation) {
  if (_sectionGeneration == generation) return;
  _sectionGeneration = generation;
  _sectionInflight.clear();
}

int _sectionGeneration = -1;

Future<void> ensureClientSections(dynamic ref, String screen) =>
    _ensureAll(ref, sectionsForClientScreen(screen));

Future<void> ensureStaffSections(dynamic ref, String screen) =>
    _ensureAll(ref, sectionsForStaffScreen(screen));

Future<void> _ensureAll(dynamic ref, Set<GymSection> sections) async {
  if (sections.isEmpty || !_hasSession()) return;
  final hold = _Hold.read(ref);
  final generation = _loadGeneration;
  await Future.wait(sections.map((section) => _ensureOne(hold, generation, section)));
}

bool _hasSession() {
  try {
    return SupabaseService.currentUser != null;
  } catch (_) {
    return false;
  }
}

Future<void> _ensureOne(_Hold hold, int generation, GymSection section) {
  final existing = _sectionInflight[section];
  if (existing != null) return existing;
  final future = _loadSection(hold, generation, section);
  _sectionInflight[section] = future;
  return future;
}

Future<void> _loadSection(_Hold hold, int generation, GymSection section) async {
  try {
    switch (section) {
      case GymSection.bookingsRest:
        final rows = await SupabaseService.loadBookings();
        if (generation != _loadGeneration) return;
        _fullBookingsLoaded = true;
        hold.bookings.setAll(rows);
        final own = hold.ownClientId;
        if (own != null) {
          hold.clientBookings.setAll(rows.where((b) => b.clientId == own).toList());
        }
      case GymSection.points:
        final rows = await SupabaseService.loadPointsLedgerAll();
        if (generation == _loadGeneration) hold.points.setAll(rows);
      case GymSection.badges:
        final rows = await SupabaseService.loadMeritBadgesAll();
        if (generation == _loadGeneration) hold.badges.setAll(rows);
      case GymSection.challenges:
        final rows = await SupabaseService.loadChallenges();
        if (generation == _loadGeneration) hold.challenges.setAll(rows);
      case GymSection.challengeTemplates:
        final rows = await SupabaseService.loadChallengeTemplates();
        if (generation == _loadGeneration) hold.templates.setAll(rows);
      case GymSection.charges:
        final rows = await SupabaseService.loadCharges();
        if (generation == _loadGeneration) hold.charges.setAll(rows);
      case GymSection.blocked:
        final rows = await SupabaseService.loadBlockedTime();
        if (generation == _loadGeneration) hold.blocked.setAll(rows);
      case GymSection.products:
        final rows = await SupabaseService.loadProducts();
        if (generation == _loadGeneration) hold.products.setAll(rows);
      case GymSection.coupons:
        final rows = await SupabaseService.loadCoupons();
        if (generation == _loadGeneration) hold.coupons.setAll(rows);
      case GymSection.programs:
        final rows = await SupabaseService.loadProgramsLibrary();
        if (generation == _loadGeneration) hold.programs.setAll(rows);
      case GymSection.nutritionLibrary:
        final rows = await SupabaseService.loadNutritionLibrary();
        if (generation == _loadGeneration) hold.nutrition.setAll(rows);
      case GymSection.meals:
        final rows = await SupabaseService.loadCustomMeals();
        if (generation == _loadGeneration) hold.meals.setAll(rows);
      case GymSection.exercises:
        final rows = await SupabaseService.loadExercises();
        if (generation != _loadGeneration || rows.isEmpty) return;
        hold.exercises.setAll(rows);
      case GymSection.squads:
        final rows = await SupabaseService.loadSquads();
        if (generation == _loadGeneration) hold.squads.setAll(rows);
      case GymSection.waitlist:
        final rows = await SupabaseService.loadWaitlist();
        if (generation == _loadGeneration) hold.waitlist.setAll(rows);
      case GymSection.categories:
        final rows = await SupabaseService.loadPackageCategories();
        if (generation == _loadGeneration) hold.categories.setAll(rows);
      case GymSection.equipment:
        final rows = await SupabaseService.loadEquipment();
        if (generation == _loadGeneration) hold.equipment.setAll(rows);
      case GymSection.forms:
        final rows = await SupabaseService.loadIntakeFormTemplates();
        if (generation == _loadGeneration) hold.forms.setAll(rows);
      case GymSection.coachBadges:
        final rows = await SupabaseService.loadCoachMeritBadges();
        if (generation == _loadGeneration) hold.coachBadges.setAll(rows);
      case GymSection.prEvents:
        final rows = await SupabaseService.loadCoachPrEvents();
        if (generation == _loadGeneration) hold.prEvents.setAll(rows);
      case GymSection.messages:
        final byClient = await SupabaseService.loadAllMessages();
        if (generation != _loadGeneration) return;
        hold.records.mergeComms(byClient);
        final own = hold.ownClientId;
        final thread = own == null ? null : byClient[own];
        if (thread != null) {
          hold.ownRecord.update((r) {
            final byId = {for (final m in r.comms) m.id: m, for (final m in thread) m.id: m};
            return r.copyWith(comms: byId.values.toList()..sort((a, b) => b.sentAt.compareTo(a.sentAt)));
          });
        }
      case GymSection.plans:
        final rows = SupabaseService.plansFromRows(await SupabaseService.fetchPlanRows());
        if (generation == _loadGeneration) hold.plans.setAll(rows);
      case GymSection.waivers:
        final rows = SupabaseService.waiversFromRows(await SupabaseService.fetchWaiverRows());
        if (generation == _loadGeneration) hold.waivers.setAll(rows);
    }
  } catch (e) {
    // A failed section can be asked for again the next time its screen opens.
    if (generation == _loadGeneration) _sectionInflight.remove(section);
    // ignore: avoid_print
    print("[loadAndSeedCoreData] $section load failed: $e");
  }
}

/// The full client record, including workout logs. The coach dashboard's
/// first read leaves those out.
Future<void> ensureFullClientRecord(dynamic ref, String clientId) {
  if (clientId.isEmpty) return Future.value();
  return _fullRecords[clientId] ??= _loadFullClientRecord(ref, clientId);
}

Future<void> _loadFullClientRecord(dynamic ref, String clientId) async {
  try {
    final record = await SupabaseService.loadClientRecord(clientId);
    final current = Map<String, ClientRecord>.from(ref.read(trainerClientRecordsProvider));
    final existing = current[clientId];
    final merged = record.copyWith(
      comms: record.comms.isEmpty ? (existing?.comms ?? const []) : record.comms,
    );
    current[clientId] = merged;
    ref.read(trainerClientRecordsProvider.notifier).setAll(current);
    if (ref.read(clientInfoProvider).id == clientId) {
      ref.read(clientRecordProvider.notifier).update((_) => merged);
    }
  } catch (e) {
    _fullRecords.remove(clientId);
    // ignore: avoid_print
    print("[ensureFullClientRecord] $e");
  }
}

Future<void> _loadPay(_Hold hold, int generation) async {
  if (_payGeneration == generation) return;
  try {
    if (SupabaseService.currentUser == null) return;
  } catch (_) {
    return;
  }
  _payGeneration = generation;
  try {
    final updated = await SupabaseService.attachTrainerPay(hold.paintedTrainers);
    if (generation != _loadGeneration) return;
    hold.paintedTrainers = updated;
    hold.trainers.setAll(updated);
    hold.markPay(true);
    final payload = _pendingPayload;
    final user = _pendingUser;
    if (payload != null && user != null) {
      payload["payRows"] = [
        for (final t in updated)
          {
            "profile_id": t.id,
            "commission_rate": t.commissionRate,
            "payout_mode": t.payoutMode,
            "payout_rate_cents": t.payoutRateCents,
            "referral_commission_percent": t.referralCommissionPercent,
          },
      ];
      await BootstrapCache.write(user, payload);
    }
  } catch (e) {
    if (generation == _loadGeneration) _payGeneration = -1;
    // ignore: avoid_print
    print("[ensureTrainerPay] $e");
  }
}

Future<void> ensureTrainerPay(dynamic ref) {
  final hold = _Hold.read(ref);
  hold.paintedTrainers = List<Trainer>.from(ref.read(trainersProvider) as List<Trainer>);
  hold.payReady = ref.read(trainerPayReadyProvider);
  return _loadPay(hold, _loadGeneration);
}

class TrainerPayReady extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
  bool get ready => state;
}

final trainerPayReadyProvider = NotifierProvider<TrainerPayReady, bool>(TrainerPayReady.new);

class _Hold {
  _Hold.read(dynamic ref)
      : roster = ref.read(trainerRosterProvider.notifier),
        trainers = ref.read(trainersProvider.notifier),
        bookings = ref.read(allBookingsProvider.notifier),
        plans = ref.read(membershipPlansProvider.notifier),
        waivers = ref.read(waiversProvider.notifier),
        settings = ref.read(platformSettingsProvider.notifier),
        records = ref.read(trainerClientRecordsProvider.notifier),
        role = ref.read(roleProvider.notifier),
        auth = ref.read(trainerAuthProvider.notifier),
        info = ref.read(clientInfoProvider.notifier),
        ownRecord = ref.read(clientRecordProvider.notifier),
        clientBookings = ref.read(clientBookingsProvider.notifier),
        signedIn = ref.read(clientSignedInProvider.notifier),
        mode = ref.read(trainerModeProvider.notifier),
        pay = ref.read(trainerPayReadyProvider.notifier),
        points = ref.read(pointsLedgerProvider.notifier),
        badges = ref.read(earnedBadgesProvider.notifier),
        challenges = ref.read(challengesProvider.notifier),
        templates = ref.read(challengeTemplatesProvider.notifier),
        charges = ref.read(chargesProvider.notifier),
        blocked = ref.read(blockedTimesProvider.notifier),
        products = ref.read(productsProvider.notifier),
        coupons = ref.read(couponsProvider.notifier),
        programs = ref.read(programsLibraryProvider.notifier),
        nutrition = ref.read(nutritionLibraryProvider.notifier),
        meals = ref.read(customMealsProvider.notifier),
        exercises = ref.read(exerciseCatalogProvider.notifier),
        squads = ref.read(squadsProvider.notifier),
        waitlist = ref.read(waitlistProvider.notifier),
        categories = ref.read(packageCategoriesProvider.notifier),
        equipment = ref.read(equipmentProvider.notifier),
        forms = ref.read(intakeFormTemplatesProvider.notifier),
        coachBadges = ref.read(coachMeritBadgesProvider.notifier),
        prEvents = ref.read(coachPrEventsProvider.notifier),
        owners = ref.read(ownerDirectoryProvider.notifier),
        extras = ref.read(dashboardExtrasProvider.notifier),
        details = ref.read(homeDetailsReadyProvider.notifier);

  final TrainerRosterNotifier roster;
  final TrainersNotifier trainers;
  final AllBookingsNotifier bookings;
  final MembershipPlansNotifier plans;
  final WaiversNotifier waivers;
  final PlatformSettingsNotifier settings;
  final TrainerClientRecordsNotifier records;
  final RoleNotifier role;
  final TrainerAuthNotifier auth;
  final ClientInfoNotifier info;
  final ClientRecordNotifier ownRecord;
  final ClientBookingsNotifier clientBookings;
  final ClientSignedIn signedIn;
  final TrainerModeNotifier mode;
  final TrainerPayReady pay;
  final PointsLedgerNotifier points;
  final EarnedBadgesNotifier badges;
  final ChallengesNotifier challenges;
  final ChallengeTemplatesNotifier templates;
  final ChargesNotifier charges;
  final BlockedTimesNotifier blocked;
  final ProductsNotifier products;
  final CouponsNotifier coupons;
  final ProgramsLibraryNotifier programs;
  final NutritionLibraryNotifier nutrition;
  final CustomMealsNotifier meals;
  final ExerciseCatalogNotifier exercises;
  final SquadsNotifier squads;
  final WaitlistNotifier waitlist;
  final PackageCategoriesNotifier categories;
  final EquipmentNotifier equipment;
  final IntakeFormTemplatesNotifier forms;
  final CoachMeritBadgesNotifier coachBadges;
  final CoachPrEventsNotifier prEvents;
  final OwnerDirectory owners;
  final DashboardExtrasNotifier extras;
  final HomeDetailsReady details;

  bool payReady = false;
  List<Trainer> paintedTrainers = const [];
  String? ownClientId;

  void markPay(bool ready) {
    payReady = ready;
    pay.set(ready);
  }
}

/// Bumped by every [loadAndSeedCoreData] call; see `later` inside it.
int _loadGeneration = 0;

/// Matches [_loadGeneration] once pay rates for that sign-in have been read.
int _payGeneration = -1;


/// Re-reads membership state — plan, freeze, cancellation — from the
/// server so a change made on another device shows here. A signed-in
/// client refreshes their own row; staff refresh the roster ([onlyId]
/// limits that to one client). Called when the app comes back to the
/// foreground and by the `clients` realtime channel.
Future<void> refreshClientInfos(dynamic ref, {String? onlyId}) async {
  if (SupabaseService.currentUser == null) return;
  if (ref.read(clientSignedInProvider) == true) {
    final ownId = ref.read(clientInfoProvider).id as String;
    if (ownId.isEmpty || (onlyId != null && onlyId != ownId)) return;
    final fresh = await SupabaseService.loadClientById(ownId);
    if (fresh != null) ref.read(clientInfoProvider.notifier).update((_) => fresh);
    return;
  }
  if (ref.read(trainerAuthProvider) == null) return;
  if (onlyId != null) {
    final fresh = await SupabaseService.loadClientById(onlyId);
    if (fresh != null) ref.read(trainerRosterProvider.notifier).update(onlyId, (_) => fresh);
  } else {
    ref.read(trainerRosterProvider.notifier).setAll(await SupabaseService.loadRoster());
  }
}

/// Shared by squad_dashboard_screen.dart (client) and squad_tab.dart (coach)
/// — every Squad mutation in both follows this same compute-then-persist-
/// then-apply shape. Returns whether the write succeeded; local state is
/// only ever updated after the real write does, so a failed save can't
/// leave the UI showing something the database doesn't actually have.
Future<bool> mutateSquad(dynamic ref, Squad squad, Squad Function(Squad) f) async {
  final next = f(squad);
  try {
    await SupabaseService.updateSquadRow(
      squad.id,
      name: next.name,
      memberIds: next.memberIds,
      memberMeta: next.memberMeta,
      maxSize: next.maxSize,
      pendingInvites: next.pendingInvites,
      activity: next.activity,
      billingShared: next.billingShared,
      chat: next.chat,
    );
  } catch (e) {
    return false;
  }
  ref.read(squadsProvider.notifier).update(squad.id, (_) => next);
  return true;
}
