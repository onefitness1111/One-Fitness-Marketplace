import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "package:onefitness/core/chat/owner_inbox.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/exercise_def.dart";
import "package:onefitness/data/providers/beep_providers.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/dashboard_load.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/data/providers/supabase_bootstrap_provider.dart";
import "package:onefitness/features/client/drawer_screens/history_screen.dart";
import "package:onefitness/features/client/drawer_screens/profile_settings_screen.dart";
import "package:onefitness/features/client/plans/workout_tab.dart";
import "package:onefitness/features/client/shell/client_shell.dart";
import "package:onefitness/features/client/shop/shop_screen.dart";
import "package:onefitness/features/trainer/exercises/exercises_screen.dart";
import "package:onefitness/features/trainer/schedule/calendar_sync_page.dart";
import "package:onefitness/features/trainer/shell/trainer_shell.dart";
import "package:onefitness/features/trainer/shell/trainer_shell_state.dart";
import "package:onefitness/core/widgets/animated_tab_icon.dart";

String _read(String path) => File(path).readAsStringSync();

/// Code with `//` comments removed, so a check is about what ships.
String _code(String path) => _read(path)
    .split("\n")
    .where((l) => !l.trimLeft().startsWith("//"))
    .join("\n");

void main() {

  void ignoreOverflow() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains("overflowed by")) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  Future<ProviderContainer> bootStaff(WidgetTester tester, {String? as}) async {
    ignoreOverflow();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    container.read(trainerAuthProvider.notifier).signIn(as ?? container.read(trainersProvider).first.id);
    container.read(trainerModeProvider.notifier).reset();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TrainerShell()),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
  }

  Finder inDrawer(String text) => find.descendant(of: find.byType(Drawer), matching: find.text(text));

  Future<void> scrollDrawerTo(WidgetTester tester, Finder item) async {
    await tester.scrollUntilVisible(item, 60,
        scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
  }

  group("U2 Collect Payments", () {
    testWidgets("is always in the owner menu and opens the page", (tester) async {
      final c = await bootStaff(tester, as: "owner");
      await openDrawer(tester);
      final item = inDrawer("Collect Payments");
      await scrollDrawerTo(tester, item);
      expect(item, findsOneWidget);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(c.read(trainerModeProvider), "collect");
    });

    test("is in the wide-screen owner nav too", () {
      final src = _code("lib/features/trainer/shell/trainer_shell.dart");
      expect(src, contains('add("collect", "Collect Payments", LucideIcons.wallet);'));
    });
  });

  group("U3 Coach Chats", () {
    test("is a filter in the owner's Chat and the dead teamchat key is gone", () {
      expect(ownerCoachFilters(const []).map((o) => o.label), contains("Coach Chats"));
      final shell = _code("lib/features/trainer/shell/trainer_shell.dart");
      expect(shell.contains('"teamchat"'), isFalse);
      expect(_code("lib/data/providers/dashboard_load.dart").contains('"teamchat"'), isFalse);
      expect(sectionsForStaffScreen("teamchat"), isEmpty);
    });

    test("a coach's Chat list has a Coach Chats filter, not a tab", () {
      // The chat page sits behind a phone-number gate that needs live
      // Supabase, so this checks the shipped list code directly.
      final src = _code("lib/features/trainer/chat/coach_chat_screen.dart");
      expect(src, contains('key: const Key("coach-chat-filter")'));
      expect(src, contains('labels: const ["All chats", kTeamChatLabel]'));
      expect(kTeamChatLabel, "Coach Chats");
      final shell = _code("lib/features/trainer/shell/trainer_shell.dart");
      expect(shell.contains("TeamChatScreen"), isFalse, reason: "no separate Coach Chats tab/page");
    });
  });

  group("U4 Access Hub", () {
    test("no client-facing text says Membership Hub", () {
      final hits = <String>[];
      for (final f in Directory("lib").listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith(".dart")) continue;
        final code = _code(f.path).split("\n").where((l) => !l.trimLeft().startsWith("///"));
        for (final line in code) {
          if (line.contains('"') && line.contains("Membership Hub")) hits.add("${f.path}: $line");
        }
      }
      expect(hits, isEmpty);
    });

    test("Profile Settings calls the plan page Access Hub", () {
      final src = _code("lib/features/client/drawer_screens/profile_settings_screen.dart");
      expect(src, contains('label: "Access Hub"'));
      expect(src.contains('label: "Membership"'), isFalse);
    });
  });

  group("U5 client Merit Badges", () {
    test("only Profile Settings opens the gallery", () {
      final shell = _code("lib/features/client/shell/client_shell.dart");
      expect(shell.contains('_NavItem("badges"'), isFalse, reason: "no menu row");
      expect(shell.contains('onOpenBadges'), isFalse, reason: "no Rewards link");
      expect(shell.contains('onGoBadges'), isFalse, reason: "no Dashboard link");
      expect(_code("lib/features/client/dashboard/client_dashboard_screen.dart").contains("See all Merit Badges"), isFalse);
    });

    testWidgets("Profile Settings has a Merit Badges row that opens the gallery", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(500, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: ProfileSettingsScreen(onReschedule: (_) {}))),
      ));
      await tester.pumpAndSettle();
      expect(find.text("Access Hub"), findsOneWidget);
      await tester.tap(find.text("Merit Badges"));
      await tester.pumpAndSettle();
      expect(find.text("Profile Settings"), findsWidgets, reason: "back bar returns to Profile Settings");
      expect(find.text("Merit Badges"), findsNothing, reason: "the row is replaced by the gallery");
    });
  });

  group("U6 past sessions", () {
    testWidgets("History is the full list of past sessions", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(500, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final me = c.read(clientInfoProvider).id;
      final coach = c.read(trainersProvider).first.id;
      c.read(clientBookingsProvider.notifier).setAll([
        Booking(id: "p1", clientId: me, trainerId: coach, date: "2025-01-02", slot: 600, sessionType: "private", discipline: "strength", attendanceStatus: "checked-in"),
        Booking(id: "p2", clientId: me, trainerId: coach, date: "2025-02-03", slot: 600, sessionType: "private", discipline: "strength"),
        Booking(id: "f1", clientId: me, trainerId: coach, date: "2999-01-01", slot: 600, sessionType: "private", discipline: "strength"),
      ]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: HistoryScreen())),
      ));
      await tester.pumpAndSettle();
      expect(find.text("PAST SESSIONS"), findsOneWidget);
      expect(find.byKey(const Key("past-session-p1")), findsOneWidget);
      expect(find.byKey(const Key("past-session-p2")), findsOneWidget);
      expect(find.byKey(const Key("past-session-f1")), findsNothing, reason: "upcoming isn't past");
      // Newest first.
      expect(tester.getTopLeft(find.byKey(const Key("past-session-p2"))).dy,
          lessThan(tester.getTopLeft(find.byKey(const Key("past-session-p1"))).dy));
    });

    testWidgets("Visits > Past Visits links to History instead of repeating it", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(500, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: ProfileSettingsScreen(onReschedule: (_) {}, onOpenHistory: () => opened++)),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Visits"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Past Visits"));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("visits-open-history")));
      expect(opened, 1);
    });

    test("the Dashboard calendar links to History", () {
      final shell = _code("lib/features/client/shell/client_shell.dart");
      expect(shell, contains('onGoHistory: () => go("history")'));
      expect(_code("lib/features/client/dashboard/client_dashboard_screen.dart"), contains("See past sessions in History"));
    });
  });

  group("U7 one Staff page", () {
    testWidgets("Staff tab has the approval code, the coach list, add and edit", (tester) async {
      final c = await bootStaff(tester, as: "owner");
      c.read(trainerPayReadyProvider.notifier).set(true);
      await tester.tap(find.descendant(of: find.byType(AnimatedTabIcon), matching: find.textContaining("Staff")));
      await tester.pumpAndSettle();
      expect(c.read(trainerModeProvider), "staff");
      expect(find.text("Staff"), findsWidgets, reason: "page title");
      expect(find.text("Coach Approval Code"), findsOneWidget);
      expect(find.text("Generate New Code"), findsOneWidget);
      expect(find.textContaining("ALL COACHES ("), findsOneWidget);
      expect(find.byKey(const Key("staff-add-trainer")), findsOneWidget);

      final coach = c.read(trainersProvider).first;
      await tester.tap(find.text(coach.displayTitle).first);
      await tester.pumpAndSettle();
      expect(find.text("Remove coach"), findsOneWidget);
      expect(find.textContaining("Coach Merit Badges"), findsOneWidget);
      final edit = find.byKey(Key("staff-edit-${coach.id}"));
      expect(edit, findsOneWidget);
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.text("Coach Approval Code"), findsNothing, reason: "the full editor is open");
    });

    test("the old Coaches key lands on Staff and the owner menu has no Coaches row", () {
      expect(kTrainerModeAliases["coaches"], "staff");
      final src = _code("lib/features/trainer/shell/trainer_shell.dart");
      expect(src.contains('"coaches" when isOwner'), isFalse);
      expect(src.contains('add("coaches"'), isFalse);
      expect(staffNavLabel(0), "Staff");
      expect(staffNavLabel(2), "Staff (2 new)");
    });

    testWidgets("a stale coaches mode opens the Staff page", (tester) async {
      final c = await bootStaff(tester, as: "owner");
      c.read(trainerModeProvider.notifier).go("coaches");
      await tester.pumpAndSettle();
      expect(find.text("Coach Approval Code"), findsOneWidget);
    });
  });

  group("U8 coach badge progress", () {
    test("is on My Profile only", () {
      expect(_code("lib/features/trainer/staff/my_pay_screen.dart").contains("CoachBadgeProgressList"), isFalse);
      expect(_code("lib/features/trainer/staff/my_profile_screen.dart"), contains("CoachMeritBadgesScreen()"));
      expect(kTrainerModeAliases["coachbadges"], "myprofile");
    });

    testWidgets("My Profile opens Merit Badges", (tester) async {
      final c = await bootStaff(tester);
      c.read(trainerModeProvider.notifier).go("myprofile");
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("my-profile-merit-badges")));
      await tester.pumpAndSettle();
      expect(find.text("THIS MONTH'S PROGRESS"), findsOneWidget);
    });
  });

  group("U9 Recurring Booking", () {
    test("one option named Recurring Booking; the old key is an alias", () {
      expect(kClientScreenAliases["advancedBooking"], "recurringBooking");
      final hits = <String>[];
      for (final f in Directory("lib").listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith(".dart")) continue;
        for (final line in _code(f.path).split("\n")) {
          if (line.contains('"') && line.contains("Advanced Booking")) hits.add("${f.path}: $line");
        }
      }
      expect(hits, isEmpty);
      expect(sectionsForClientScreen("recurringBooking"), sectionsForClientScreen("booking"));
    });
  });

  group("U11 Shop", () {
    testWidgets("has My Orders at the top", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: ShopScreen()))));
      await tester.pumpAndSettle();
      final btn = find.byKey(const Key("shop-my-orders"));
      expect(btn, findsOneWidget);
      expect(tester.getTopLeft(btn).dy, lessThan(80));
    });
  });

  group("U13 Calendar Sync", () {
    test("the owner's preview is only their own upcoming sessions", () {
      const today = "2026-11-25";
      final rows = [
        const Booking(id: "a", clientId: "c1", trainerId: "owner-1", date: "2026-11-27", slot: 600, sessionType: "private", discipline: "strength"),
        const Booking(id: "b", clientId: "c1", trainerId: "coach-2", date: "2026-11-26", slot: 600, sessionType: "private", discipline: "strength"),
        const Booking(id: "c", clientId: "c1", trainerId: "owner-1", date: "2026-11-20", slot: 600, sessionType: "private", discipline: "strength"),
        const Booking(id: "d", clientId: "c1", trainerId: "owner-1", date: "2026-11-26", slot: 540, sessionType: "private", discipline: "strength"),
      ];
      expect(calendarFeedPreview(rows, trainerId: "owner-1", today: today).map((b) => b.id), ["d", "a"]);
      expect(calendarFeedPreview(rows, trainerId: null, today: today), isEmpty);
    });

    testWidgets("the owner's page lists their own sessions instead of blank", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(trainerAuthProvider.notifier).signIn("owner");
      c.read(allBookingsProvider.notifier).setAll([
        const Booking(id: "own", clientId: "c1", trainerId: "owner-1", date: "2999-01-01", slot: 600, sessionType: "private", discipline: "strength"),
        const Booking(id: "theirs", clientId: "c1", trainerId: "coach-2", date: "2999-01-01", slot: 600, sessionType: "private", discipline: "strength"),
      ]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: CalendarSyncPage(ownerProfileIdOverride: "owner-1"))),
      ));
      await tester.pumpAndSettle();
      expect(find.text("Sync to Calendar"), findsOneWidget);
      expect(find.byKey(const Key("calendar-preview-own")), findsOneWidget);
      expect(find.byKey(const Key("calendar-preview-theirs")), findsNothing);
    });
  });

  group("L2 coach starts the session", () {
    testWidgets("the workout page opens the coach-led day with a message banner, no pop-up", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: WorkoutTab())),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key("coach-led-banner")), findsNothing);
      final client = c.read(clientRecordProvider);
      final day = client.savedPrograms.firstWhere((p) => p.status == "active" && p.programDays.isNotEmpty).programDays.last;
      c.read(coachLedDaysProvider.notifier).setAll([CoachLedDay(clientId: client.id, dayId: day.id, trainerId: "demo-marcus")]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key("coach-led-banner")), findsOneWidget);
      expect(find.text("Message your coach"), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text("Program"), findsOneWidget, reason: "the logging page is open");
    });

    test("the live session layer no longer shows the Message/Close pop-up", () {
      final src = _code("lib/features/client/beep/client_live_session_layer.dart");
      expect(src.contains("showDialog"), isFalse);
      expect(src.contains("Your session has started"), isFalse);
      expect(src, contains("widget.onOpenWorkout?.call()"));
      expect(src, contains("kBeepYourCoachEnabled && coachLiveBarShowsBeep"));
    });
  });

  group("O2 coaches keep exercise add/edit/delete", () {
    testWidgets("a coach can add, open and delete an exercise", (tester) async {
      ignoreOverflow();
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(trainerAuthProvider.notifier).signIn("demo-marcus");
      c.read(exerciseCatalogProvider.notifier).upsert(
            const ExerciseDef(id: "ex-1", name: "Goblet Squat", movementPattern: "squat", primaryMuscle: "Quads"),
          );
      c.read(exerciseCatalogStatusProvider.notifier).set(ExerciseCatalogStatus.loaded);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: ExercisesScreen())),
      ));
      await tester.pumpAndSettle();
      expect(find.text("New exercise"), findsOneWidget);
      await tester.tap(find.text("Goblet Squat"));
      await tester.pumpAndSettle();
      final del = find.text("Delete exercise");
      await tester.scrollUntilVisible(del, 200, scrollable: find.byType(Scrollable).first);
      expect(del, findsOneWidget);
    });

    test("the coach menu still lists Exercises and the page has no owner gate", () {
      final shell = _code("lib/features/trainer/shell/trainer_shell.dart");
      expect(shell, contains('"exercises" => const ExercisesScreen()'));
      final ex = _code("lib/features/trainer/exercises/exercises_screen.dart");
      expect(ex.contains('== "owner"'), isFalse);
    });
  });

  test("hard rules: Beep stays off and no primary_trainer_id is added", () {
    expect(_read("lib/core/feature_flags.dart"), contains("kBeepYourCoachEnabled = false"));
    for (final p in [
      "lib/features/trainer/staff/staff_screen.dart",
      "lib/features/trainer/staff/coaches_overview_screen.dart",
      "lib/features/trainer/schedule/calendar_sync_page.dart",
      "lib/features/client/drawer_screens/history_screen.dart",
      "lib/features/client/drawer_screens/past_session_card.dart",
    ]) {
      expect(_read(p).contains("primary_trainer_id"), isFalse, reason: p);
    }
  });
}
