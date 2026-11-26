import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/staff/change_role.dart";
import "package:onefitness/features/trainer/staff/coaches_overview_screen.dart";

String _read(String path) => File(path).readAsStringSync();

/// Code with `//` comments removed, so a check is about what ships.
String _code(String path) => _read(
  path,
).split("\n").where((l) => !l.trimLeft().startsWith("//")).join("\n");

void main() {
  const client = ClientInfo(id: "c-1", name: "Casey Client");

  Future<ProviderContainer> boot(
    WidgetTester tester, {
    required String? signedInAs,
    required Widget child,
    List<ClientInfo> roster = const [client],
    List<Booking> bookings = const [],
  }) async {
    // The Staff page overflows a little at test size; that is not what
    // these tests are about.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains("overflowed by")) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    if (signedInAs != null) {
      container.read(trainerAuthProvider.notifier).signIn(signedInAs);
    }
    container.read(trainerRosterProvider.notifier).setAll(roster);
    container.read(allBookingsProvider.notifier).setAll(bookings);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group("who sees Change role", () {
    testWidgets("the owner does", (tester) async {
      await boot(
        tester,
        signedInAs: "owner",
        child: const ChangeRoleAction(
          profileId: "c-1",
          name: "Casey Client",
          currentRole: "client",
        ),
      );
      expect(find.byKey(const Key("change-role-c-1")), findsOneWidget);
      expect(find.text("Change role"), findsOneWidget);
    });

    testWidgets("a coach does not", (tester) async {
      await boot(
        tester,
        signedInAs: "demo-marcus",
        child: const ChangeRoleAction(
          profileId: "c-1",
          name: "Casey Client",
          currentRole: "client",
        ),
      );
      expect(find.byKey(const Key("change-role-c-1")), findsNothing);
      expect(find.text("Change role"), findsNothing);
    });

    testWidgets("nobody signed in does not see it", (tester) async {
      await boot(
        tester,
        signedInAs: null,
        child: const ChangeRoleAction(
          profileId: "c-1",
          name: "Casey Client",
          currentRole: "client",
        ),
      );
      expect(find.text("Change role"), findsNothing);
    });

    testWidgets("it is never offered for an owner account", (tester) async {
      await boot(
        tester,
        signedInAs: "owner",
        child: const ChangeRoleAction(
          profileId: "o-1",
          name: "The Owner",
          currentRole: "owner",
        ),
      );
      expect(find.text("Change role"), findsNothing);
    });

    testWidgets("each coach card on the Staff page has it, for the owner", (
      tester,
    ) async {
      final container = await boot(
        tester,
        signedInAs: "owner",
        child: const SizedBox(height: 2000, child: CoachesOverviewScreen()),
      );
      final first = container.read(trainersProvider).first;
      expect(
        find.byKey(Key("change-role-${first.id}")),
        findsNothing,
        reason: "the card is closed until it is tapped",
      );
      await tester.tap(find.text(first.displayTitle).first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(Key("change-role-${first.id}")),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(Key("change-role-${first.id}")), findsOneWidget);
    });
  });

  group("the choices", () {
    testWidgets(
      "offers Client and Coach only, never Owner, and marks the current one",
      (tester) async {
        await boot(
          tester,
          signedInAs: "owner",
          child: const ChangeRoleAction(
            profileId: "c-1",
            name: "Casey Client",
            currentRole: "client",
          ),
        );
        await tester.tap(find.byKey(const Key("change-role-c-1")));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key("change-role-picker")), findsOneWidget);
        expect(
          find.byKey(const Key("change-role-option-client")),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key("change-role-option-coach")),
          findsOneWidget,
        );
        expect(find.text("Owner"), findsNothing);
        expect(find.text("Current"), findsOneWidget);
        // Tapping the person's current role does nothing.
        await tester.tap(
          find.byKey(const Key("change-role-option-client")),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key("change-role-picker")), findsOneWidget);
      },
    );
  });

  group("the confirmation", () {
    testWidgets("says what changes, and Cancel changes nothing", (
      tester,
    ) async {
      final calls = <String>[];
      await boot(
        tester,
        signedInAs: "owner",
        child: ChangeRoleAction(
          profileId: "c-1",
          name: "Casey Client",
          currentRole: "client",
          setRole: (id, role) async => calls.add("$id:$role"),
        ),
      );
      await tester.tap(find.byKey(const Key("change-role-c-1")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("change-role-option-coach")));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key("change-role-dialog")), findsOneWidget);
      expect(
        find.text(
          "Casey Client will become a Coach and will see the coach app on next sign-in.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key("change-role-cancel")), findsOneWidget);
      expect(find.byKey(const Key("change-role-confirm")), findsOneWidget);
      await tester.tap(find.byKey(const Key("change-role-cancel")));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.byKey(const Key("change-role-dialog")), findsNothing);
    });

    testWidgets("Confirm makes the one server call with the chosen role", (
      tester,
    ) async {
      final calls = <String>[];
      var changed = 0;
      await boot(
        tester,
        signedInAs: "owner",
        child: ChangeRoleAction(
          profileId: "c-1",
          name: "Casey Client",
          currentRole: "client",
          onChanged: () => changed++,
          setRole: (id, role) async => calls.add("$id:$role"),
        ),
      );
      await tester.tap(find.byKey(const Key("change-role-c-1")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("change-role-option-coach")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("change-role-confirm")));
      await tester.pumpAndSettle();
      expect(calls, ["c-1:coach"]);
      expect(changed, 1);
      expect(find.textContaining("is now a Coach"), findsOneWidget);
    });

    testWidgets(
      "a refused change shows the server's reason and does not report success",
      (tester) async {
        var changed = 0;
        await boot(
          tester,
          signedInAs: "owner",
          child: ChangeRoleAction(
            profileId: "c-1",
            name: "Casey Client",
            currentRole: "client",
            onChanged: () => changed++,
            setRole: (id, role) async =>
                throw Exception("That account was not found."),
          ),
        );
        await tester.tap(find.byKey(const Key("change-role-c-1")));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key("change-role-option-coach")));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key("change-role-confirm")));
        await tester.pumpAndSettle();
        expect(find.text("That account was not found."), findsOneWidget);
        expect(changed, 0);
      },
    );

    testWidgets("a client with a membership is warned it keeps billing", (
      tester,
    ) async {
      const member = ClientInfo(
        id: "c-2",
        name: "Max Member",
        stripeSubscriptionId: "sub_123",
      );
      await boot(
        tester,
        signedInAs: "owner",
        roster: [member],
        child: const ChangeRoleAction(
          profileId: "c-2",
          name: "Max Member",
          currentRole: "client",
        ),
      );
      await tester.tap(find.byKey(const Key("change-role-c-2")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("change-role-option-coach")));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("keeps billing until you cancel it"),
        findsOneWidget,
      );
    });

    testWidgets("a client with no membership gets no billing warning", (
      tester,
    ) async {
      await boot(
        tester,
        signedInAs: "owner",
        child: const ChangeRoleAction(
          profileId: "c-1",
          name: "Casey Client",
          currentRole: "client",
        ),
      );
      await tester.tap(find.byKey(const Key("change-role-c-1")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key("change-role-option-coach")));
      await tester.pumpAndSettle();
      expect(find.textContaining("keeps billing"), findsNothing);
    });

    testWidgets(
      "a coach with upcoming sessions is warned they are not cancelled",
      (tester) async {
        final soon = addDaysIsoForTest(isoToday(), 3);
        final bookings = [
          Booking(
            id: "b1",
            clientId: "c-1",
            trainerId: "t-1",
            date: soon,
            slot: 480,
            sessionType: "one-on-one",
            discipline: "pt",
          ),
          Booking(
            id: "b2",
            clientId: "c-1",
            trainerId: "t-1",
            date: soon,
            slot: 540,
            sessionType: "one-on-one",
            discipline: "pt",
          ),
          Booking(
            id: "b3",
            clientId: "c-1",
            trainerId: "t-1",
            date: soon,
            slot: 600,
            sessionType: "one-on-one",
            discipline: "pt",
            status: "cancelled",
          ),
          Booking(
            id: "b4",
            clientId: "c-1",
            trainerId: "t-1",
            date: "2020-01-01",
            slot: 480,
            sessionType: "one-on-one",
            discipline: "pt",
          ),
          Booking(
            id: "b5",
            clientId: "c-1",
            trainerId: "someone-else",
            date: soon,
            slot: 480,
            sessionType: "one-on-one",
            discipline: "pt",
          ),
        ];
        await boot(
          tester,
          signedInAs: "owner",
          bookings: bookings,
          child: const ChangeRoleAction(
            profileId: "t-1",
            name: "Tess Coach",
            currentRole: "coach",
          ),
        );
        await tester.tap(find.byKey(const Key("change-role-t-1")));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key("change-role-option-client")));
        await tester.pumpAndSettle();
        expect(
          find.text(
            "Tess Coach will become a Client and will see the client app on next sign-in.",
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining("2 upcoming sessions as a coach"),
          findsOneWidget,
        );
        expect(find.textContaining("not cancelled"), findsOneWidget);
      },
    );
  });

  group("the wording", () {
    test("a client becoming a coach", () {
      const plan = RoleChangePlan(name: "Casey", from: "client", to: "coach");
      expect(
        plan.headline,
        "Casey will become a Coach and will see the coach app on next sign-in.",
      );
      expect(plan.warnings, [
        "Past sessions, payments and history stay as they are.",
      ]);
    });

    test("only the relevant warning shows for each direction", () {
      const toCoach = RoleChangePlan(
        name: "A",
        from: "client",
        to: "coach",
        hasMembership: true,
        upcomingSessions: 4,
      );
      expect(toCoach.warnings.length, 2);
      expect(toCoach.warnings.first, contains("keeps billing"));
      const toClient = RoleChangePlan(
        name: "A",
        from: "coach",
        to: "client",
        hasMembership: true,
        upcomingSessions: 1,
      );
      expect(
        toClient.warnings.first,
        contains("1 upcoming session as a coach"),
      );
      expect(toClient.warnings.any((w) => w.contains("billing")), isFalse);
    });

    test("only Client and Coach exist as choices", () {
      expect(kChangeRoleOptions, ["client", "coach"]);
    });
  });

  group("source rules", () {
    final ui = _code("lib/features/trainer/staff/change_role.dart");

    test("no coach-client assignment and no AI wording", () {
      expect(ui.contains("primary_trainer_id"), isFalse);
      expect(ui.contains("primaryTrainer"), isFalse);
      expect(RegExp(r"\bAI\b").hasMatch(ui), isFalse);
    });

    test("it is on the Staff page's coach cards and on the client profile", () {
      expect(
        _code("lib/features/trainer/staff/coaches_overview_screen.dart"),
        contains("ChangeRoleAction("),
      );
      expect(
        _code("lib/features/trainer/clients/profile_tab.dart"),
        contains("ChangeRoleAction("),
      );
    });

    test(
      "the app calls set_user_role and nothing writes profiles.role directly",
      () {
        final service = _code("lib/core/supabase/supabase_service.dart");
        expect(service, contains('rpc("set_user_role"'));
        expect(RegExp(r'"role"\s*:').allMatches(ui).isEmpty, isTrue);
      },
    );
  });
}

String addDaysIsoForTest(String iso, int days) {
  final d = DateTime.parse(iso).add(Duration(days: days));
  return "${d.year.toString().padLeft(4, "0")}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";
}
