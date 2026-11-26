import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/charge.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/points_ledger_entry.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/coach_permissions_provider.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/reports/reports_hub_screen.dart";
import "package:onefitness/features/trainer/schedule/balance_booking_warning.dart";
import "package:onefitness/features/trainer/staff/coaches_overview_screen.dart";
import "package:onefitness/features/trainer/staff/coach_permission_switches.dart";

String _code(String path) =>
    File(path).readAsStringSync().split("\n").where((l) => !l.trimLeft().startsWith("//")).join("\n");

Booking _booking(String id, String clientId, String trainerId) => Booking(
      id: id,
      clientId: clientId,
      trainerId: trainerId,
      date: "2026-11-10",
      slot: 540,
      sessionType: "semi-private",
      discipline: "personal-training",
    );

Charge _charge(String id, String clientId, String? trainerId) => Charge(
      id: id,
      clientId: clientId,
      clientName: "Client",
      type: "purchase",
      date: "2026-11-10",
      amount: 50,
      trainerId: trainerId,
    );

void main() {
  const mine = "coach-me";
  const other = "coach-other";

  ProviderContainer container({String? signedInAs, Map<String, CoachPermissions>? perms, CoachReportData? report}) {
    final c = ProviderContainer(overrides: [
      if (report != null) coachReportDataProvider.overrideWith((ref) async => report),
    ]);
    addTearDown(c.dispose);
    if (signedInAs != null) c.read(trainerAuthProvider.notifier).signIn(signedInAs);
    if (perms != null) c.read(coachPermissionsProvider.notifier).setAll(perms);
    return c;
  }

  group("the six switches", () {
    test("names, labels and database columns", () {
      expect(CoachPermission.values.map((p) => p.column), [
        "billing_access",
        "charge_fees",
        "edit_plans",
        "send_texts",
        "manage_other_schedules",
        "see_own_revenue",
      ]);
      for (final p in CoachPermission.values) {
        expect(p.label.trim(), isNotEmpty);
        expect(p.label.length, lessThan(32), reason: "short label");
        expect(p.help.trim(), isNotEmpty);
      }
    });

    test("a row maps to switches, and a missing column is off", () {
      final p = CoachPermissions.fromRow({"billing_access": true, "send_texts": true, "charge_fees": false});
      expect(p.allows(CoachPermission.billingAccess), isTrue);
      expect(p.allows(CoachPermission.sendTexts), isTrue);
      expect(p.allows(CoachPermission.chargeFees), isFalse);
      expect(p.allows(CoachPermission.editPlans), isFalse);
      expect(CoachPermissions.none.count, 0);
      expect(CoachPermissions.all.count, 6);
    });
  });

  group("coachCanProvider", () {
    test("the owner can always do everything, loaded or not", () {
      final c = container(signedInAs: "owner", perms: {});
      for (final p in CoachPermission.values) {
        expect(c.read(coachCanProvider(p)), isTrue);
      }
    });

    test("a coach is not blocked before the answer arrives (the server enforces)", () {
      final c = container(signedInAs: mine);
      for (final p in CoachPermission.values) {
        expect(c.read(coachCanProvider(p)), isTrue);
      }
    });

    test("a coach with no row, once loaded, can do nothing", () {
      final c = container(signedInAs: mine, perms: {});
      for (final p in CoachPermission.values) {
        expect(c.read(coachCanProvider(p)), isFalse, reason: p.column);
      }
    });

    test("a coach gets exactly what is on, and not what is on for someone else", () {
      final c = container(signedInAs: mine, perms: {
        mine: const CoachPermissions({CoachPermission.sendTexts}),
        other: CoachPermissions.all,
      });
      expect(c.read(coachCanProvider(CoachPermission.sendTexts)), isTrue);
      for (final p in CoachPermission.values.where((p) => p != CoachPermission.sendTexts)) {
        expect(c.read(coachCanProvider(p)), isFalse, reason: p.column);
      }
    });

    test("turning one on updates only that switch", () {
      final c = container(signedInAs: mine, perms: {mine: CoachPermissions.none});
      c.read(coachPermissionsProvider.notifier).setOne(mine, CoachPermission.chargeFees, true);
      expect(c.read(coachCanProvider(CoachPermission.chargeFees)), isTrue);
      expect(c.read(coachCanProvider(CoachPermission.editPlans)), isFalse);
    });
  });

  group("the owner's switches on a coach card", () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required String? signedInAs,
      Map<String, CoachPermissions>? perms,
      Future<void> Function(String, CoachPermission, bool)? save,
    }) async {
      final c = container(signedInAs: signedInAs, perms: perms ?? {mine: CoachPermissions.none});
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CoachPermissionSwitches(coachId: mine, coachName: "Marcus", save: save)),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets("the owner sees all six, each with its plain-English label", (tester) async {
      await pump(tester, signedInAs: "owner");
      expect(find.text("What Marcus can do"), findsOneWidget);
      for (final p in CoachPermission.values) {
        expect(find.byKey(Key("perm-switch-$mine-${p.column}")), findsOneWidget, reason: p.column);
        expect(find.text(p.label), findsOneWidget, reason: p.column);
      }
      expect(find.byType(Switch), findsNWidgets(6));
      expect(find.textContaining("always on for every coach"), findsOneWidget);
    });

    testWidgets("a coach sees nothing", (tester) async {
      await pump(tester, signedInAs: "coach-someone");
      expect(find.byType(Switch), findsNothing);
      expect(find.text("What Marcus can do"), findsNothing);
    });

    testWidgets("nobody signed in sees nothing", (tester) async {
      await pump(tester, signedInAs: null);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets("a new coach shows every switch off; the owner turns one on and it saves", (tester) async {
      final saved = <String>[];
      final c = await pump(tester, signedInAs: "owner", save: (id, p, v) async => saved.add("$id:${p.column}:$v"));
      for (final sw in tester.widgetList<Switch>(find.byType(Switch))) {
        expect(sw.value, isFalse);
      }
      await tester.tap(find.byKey(const Key("perm-switch-$mine-send_texts")));
      await tester.pumpAndSettle();
      expect(saved, ["$mine:send_texts:true"]);
      expect(c.read(coachPermissionsForProvider(mine)).allows(CoachPermission.sendTexts), isTrue);
      expect(c.read(coachPermissionsForProvider(mine)).count, 1);
    });

    testWidgets("a failed save puts the switch back and says so", (tester) async {
      final c = await pump(tester, signedInAs: "owner", save: (id, p, v) async => throw Exception("no"));
      await tester.tap(find.byKey(const Key("perm-switch-$mine-charge_fees")));
      await tester.pumpAndSettle();
      expect(c.read(coachPermissionsForProvider(mine)).allows(CoachPermission.chargeFees), isFalse);
      expect(find.text("Couldn't save that change. Try again."), findsOneWidget);
    });

    testWidgets("switches wait for the saved values before they can be changed", (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(trainerAuthProvider.notifier).signIn("owner");
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: CoachPermissionSwitches(coachId: mine, coachName: "Marcus")))),
      ));
      await tester.pumpAndSettle();
      for (final sw in tester.widgetList<Switch>(find.byType(Switch))) {
        expect(sw.onChanged, isNull);
      }
    });
  });

  group("reports: same reports, scoped to the viewer", () {
    test("reportAvailable: owner gets all, coach never the activity log, revenue only with the switch", () {
      for (final key in {...revenueReportKeys, ...ownerOnlyReportKeys, "attendance", "utilization", "hours", "rewards"}) {
        expect(reportAvailable(key, isOwner: true, canSeeRevenue: false), isTrue, reason: key);
      }
      expect(reportAvailable("activity", isOwner: false, canSeeRevenue: true), isFalse);
      for (final key in revenueReportKeys) {
        expect(reportAvailable(key, isOwner: false, canSeeRevenue: false), isFalse, reason: key);
        expect(reportAvailable(key, isOwner: false, canSeeRevenue: true), isTrue, reason: key);
      }
      for (final key in ["attendance", "utilization", "hours", "rewards"]) {
        expect(reportAvailable(key, isOwner: false, canSeeRevenue: false), isTrue, reason: key);
      }
    });

    test("a coach's report data is exactly what the server returned, not everyone's", () {
      final c = container(
        signedInAs: mine,
        perms: {mine: CoachPermissions.none},
        report: CoachReportData(
          bookings: [_booking("b1", "c1", mine)],
          clientIds: const {"c1"},
        ),
      );
      c.read(allBookingsProvider.notifier).setAll([
        _booking("b1", "c1", mine),
        _booking("b2", "c2", other),
      ]);
      c.read(trainerRosterProvider.notifier).setAll(const [
        ClientInfo(id: "c1", name: "One"),
        ClientInfo(id: "c2", name: "Two"),
      ]);
      c.listen(coachReportDataProvider, (_, __) {});
      return Future(() async {
        await c.read(coachReportDataProvider.future);
        expect(c.read(reportBookingsProvider).map((b) => b.id), ["b1"]);
        expect(c.read(reportRosterProvider).map((r) => r.id), ["c1"]);
      });
    });

    test("until the server answers, a coach's report is empty, never the whole gym", () {
      final c = container(signedInAs: mine, perms: {mine: CoachPermissions.none});
      c.read(allBookingsProvider.notifier).setAll([_booking("b2", "c2", other)]);
      expect(c.read(reportBookingsProvider), isEmpty);
      expect(c.read(reportRosterProvider), isEmpty);
    });

    test("the owner's reports use the full gym data, unchanged", () {
      final c = container(signedInAs: "owner");
      c.read(allBookingsProvider.notifier).setAll([_booking("b1", "c1", mine), _booking("b2", "c2", other)]);
      expect(c.read(reportBookingsProvider).length, 2);
      expect(c.read(reportTrainersProvider), c.read(trainersProvider));
      expect(c.read(reportChargesProvider), c.read(chargesProvider));
    });

    test("a coach's trainer list is only themselves", () {
      final c = container(signedInAs: mine, perms: {mine: CoachPermissions.none});
      c.read(trainersProvider.notifier).setAll(const [
        Trainer(id: mine, name: "Me"),
        Trainer(id: other, name: "Other"),
      ]);
      expect(c.read(reportTrainersProvider).map((t) => t.id), [mine]);
      final owner = container(signedInAs: "owner");
      owner.read(trainersProvider.notifier).setAll(const [
        Trainer(id: mine, name: "Me"),
        Trainer(id: other, name: "Other"),
      ]);
      expect(owner.read(reportTrainersProvider).length, 2);
    });

    test("revenue: hidden without the switch, only their own charges with it, never another coach's", () {
      final charges = [
        _charge("x1", "c1", mine),
        _charge("x2", "c2", other),
        _charge("x3", "c3", null),
      ];
      final off = container(signedInAs: mine, perms: {mine: CoachPermissions.none});
      off.read(chargesProvider.notifier).setAll(charges);
      expect(off.read(reportChargesProvider), isEmpty);
      expect(off.read(reportRevenueVisibleProvider), isFalse);

      final on = container(signedInAs: mine, perms: {mine: const CoachPermissions({CoachPermission.seeOwnRevenue})});
      on.read(chargesProvider.notifier).setAll(charges);
      expect(on.read(reportChargesProvider).map((c) => c.id), ["x1"]);
      expect(on.read(reportRevenueVisibleProvider), isTrue);

      final owner = container(signedInAs: "owner");
      owner.read(chargesProvider.notifier).setAll(charges);
      expect(owner.read(reportChargesProvider).length, 3);
    });

    test("points ledger rows are limited to the coach's own clients", () {
      final c = container(
        signedInAs: mine,
        perms: {mine: CoachPermissions.none},
        report: const CoachReportData(clientIds: {"c1"}),
      );
      c.read(pointsLedgerProvider.notifier).setAll(const [
        PointsLedgerEntry(id: "p1", clientId: "c1", amount: 10, type: "earn", source: "x", createdAt: "2026-11-01"),
        PointsLedgerEntry(id: "p2", clientId: "c2", amount: 10, type: "earn", source: "x", createdAt: "2026-11-01"),
      ]);
      c.listen(coachReportDataProvider, (_, __) {});
      return Future(() async {
        await c.read(coachReportDataProvider.future);
        expect(c.read(reportLedgerProvider).map((e) => e.id), ["p1"]);
      });
    });

    Future<ProviderContainer> hub(WidgetTester tester, {required String signedInAs, Map<String, CoachPermissions>? perms}) async {
      final c = container(
        signedInAs: signedInAs,
        perms: perms,
        report: const CoachReportData(),
      );
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: ReportsHubScreen())),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets("the owner's hub lists every report, including the activity log", (tester) async {
      await hub(tester, signedInAs: "owner");
      for (final t in ["Itemized Sales", "Real-Time Charges", "Attendance Summary", "Staff Hours", "Revenue vs. Payroll", "Activity Log", "Rewards & Points"]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.byKey(const Key("reports-coach-scope")), findsNothing);
    });

    testWidgets("a coach without the revenue switch gets reports with no money in them", (tester) async {
      await hub(tester, signedInAs: mine, perms: {mine: CoachPermissions.none});
      for (final t in ["Attendance Summary", "Session Utilization", "Staff Hours", "Rewards & Points"]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      for (final t in ["Itemized Sales", "Items Sold", "Real-Time Charges", "Projected Revenue", "Service Commissions", "Payroll Summary", "Coach Merit Badges", "Revenue vs. Payroll", "Activity Log"]) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.byKey(const Key("reports-coach-scope")), findsOneWidget);
      expect(find.textContaining("Money figures are hidden"), findsOneWidget);
    });

    testWidgets("with See own revenue the coach also gets the money reports, but never the activity log", (tester) async {
      await hub(tester, signedInAs: mine, perms: {mine: const CoachPermissions({CoachPermission.seeOwnRevenue})});
      for (final t in ["Itemized Sales", "Items Sold", "Payroll Summary", "Revenue vs. Payroll", "Attendance Summary"]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text("Activity Log"), findsNothing);
      expect(find.textContaining("Money figures are your own"), findsOneWidget);
    });
  });

  group("coach screens follow the switches", () {
    testWidgets("the charge button in the balance dialog is gone without Charge fees", (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (ctx) => StaffBalanceDialog(
                  warning: "Balance \$25.00.",
                  bookAnywayEnabled: true,
                  canCharge: false,
                  onCharge: () async => null,
                ),
              ),
              child: const Text("open"),
            ),
          ),
        ),
      ));
      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key("charge-balance-book")), findsNothing);
      expect(find.byKey(const Key("book-anyway")), findsOneWidget);
    });
  });


  group("on the Staff page", () {
    Future<ProviderContainer> staffPage(WidgetTester tester, String signedInAs) async {
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains("overflowed by")) return;
        original?.call(details);
      };
      addTearDown(() => FlutterError.onError = original);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(trainerAuthProvider.notifier).signIn(signedInAs);
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SizedBox(height: 2000, child: CoachesOverviewScreen())))),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets("an opened coach card shows the six switches, off for a coach with no row", (tester) async {
      final c = await staffPage(tester, "owner");
      c.read(coachPermissionsProvider.notifier).setAll({});
      final first = c.read(trainersProvider).first;
      expect(find.byKey(Key("perm-section-${first.id}")), findsNothing, reason: "closed until tapped");
      await tester.tap(find.text(first.displayTitle).first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(Key("perm-section-${first.id}")), 200, scrollable: find.byType(Scrollable).first);
      expect(find.byKey(Key("perm-section-${first.id}")), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(6));
    });
  });

  group("source rules", () {
    const files = [
      "lib/data/providers/coach_permissions_provider.dart",
      "lib/features/trainer/staff/coach_permission_switches.dart",
      "lib/features/trainer/reports/reports_hub_screen.dart",
    ];

    test("never gates or scopes on primary_trainer_id or primaryTrainer", () {
      for (final f in files) {
        final code = _code(f);
        expect(code.contains("primary_trainer_id"), isFalse, reason: f);
        expect(code.contains("primaryTrainer"), isFalse, reason: f);
      }
    });

    test("no client phone is read or shown by the permission and report code", () {
      for (final f in files) {
        expect(RegExp(r"\.phone\b").hasMatch(_code(f)), isFalse, reason: f);
      }
    });

    test("switch wording never calls a person or a feature AI", () {
      for (final p in CoachPermission.values) {
        expect(RegExp(r"\bAI\b").hasMatch("${p.label} ${p.help}"), isFalse);
      }
    });

    test("the Staff coach card draws the switches, owner-only", () {
      final card = _code("lib/features/trainer/staff/coaches_overview_screen.dart");
      expect(card.contains("CoachPermissionSwitches(coachId: t.id"), isTrue);
      expect(_code("lib/features/trainer/staff/coach_permission_switches.dart").contains('trainerAuthProvider) != "owner"'), isTrue);
    });

    test("each gated screen asks the provider for its own switch", () {
      void uses(String file, CoachPermission p) {
        expect(_code(file).contains("CoachPermission.${p.name}"), isTrue, reason: "$file ${p.name}");
      }

      uses("lib/features/trainer/shell/trainer_shell.dart", CoachPermission.seeOwnRevenue);
      uses("lib/features/trainer/clients/profile_tab.dart", CoachPermission.editPlans);
      uses("lib/features/trainer/clients/profile_tab.dart", CoachPermission.billingAccess);
      uses("lib/features/trainer/clients/profile_tab.dart", CoachPermission.chargeFees);
      uses("lib/features/trainer/chat/coach_chat_screen.dart", CoachPermission.sendTexts);
      uses("lib/features/trainer/chat/broadcast_screen.dart", CoachPermission.sendTexts);
      uses("lib/features/trainer/schedule/create_session_sheet.dart", CoachPermission.manageOtherSchedules);
      uses("lib/features/trainer/schedule/add_manual_booking_sheet.dart", CoachPermission.manageOtherSchedules);
      uses("lib/features/trainer/schedule/balance_booking_warning.dart", CoachPermission.chargeFees);
      uses("lib/features/trainer/schedule/single_session_staff.dart", CoachPermission.chargeFees);
    });

    test("every coach gets Reports in the menu; My Pay only with See own revenue", () {
      final shell = _code("lib/features/trainer/shell/trainer_shell.dart");
      expect(shell.contains('"reports" => ReportsHubScreen('), isTrue);
      expect(shell.contains('"mypay" when canSeePay => const MyPayScreen()'), isTrue);
      expect(shell.contains('if (canSeePay) add("mypay"'), isTrue);
      expect(shell.contains('_DrawerEntry(LucideIcons.clipboardCheck, "My Pay", "mypay", canSeePay)'), isTrue);
    });

    test("only the owner finalizes merit badges, so a coach's report writes nothing", () {
      final code = _code("lib/features/trainer/reports/payroll_reports.dart");
      expect(code.contains('ref.read(trainerAuthProvider) == "owner"'), isTrue);
    });
  });
}
