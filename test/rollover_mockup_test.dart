import "dart:io";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/core/widgets/widgets.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/membership_plan.dart";
import "package:onefitness/features/trainer/clients/plan_allowance_section.dart";
import "package:onefitness/features/trainer/memberships/membership_rollover_section.dart";

Future<void> _loadRoboto() async {
  final base = "${Platform.environment["HOME"]}/flutter/bin/cache/artifacts/material_fonts";
  if (!File("$base/Roboto-Regular.ttf").existsSync()) return;
  final loader = FontLoader("Roboto");
  for (final name in ["Roboto-Regular.ttf", "Roboto-Medium.ttf", "Roboto-Bold.ttf"]) {
    final bytes = await File("$base/$name").readAsBytes();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadRoboto);

  Future<void> save(WidgetTester tester, String name) async {
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key("shot")));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory("/opt/cursor/artifacts");
      if (!dir.existsSync() || bytes == null) return;
      await File("${dir.path}/$name.png").writeAsBytes(bytes.buffer.asUint8List());
    });
  }

  Widget frame(Widget child) {
    final theme = AppTheme.themeFor(ThemeMode.dark, Brightness.dark);
    return MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: "Roboto"),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: "Roboto"),
      ),
      home: Scaffold(
        backgroundColor: AppColors.bg,
        body: Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            key: const Key("shot"),
            child: SizedBox(
              width: 390,
              child: ColoredBox(
                color: AppColors.bg,
                child: Padding(padding: const EdgeInsets.all(16), child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets("membership editor shows the rollover limit and apply action", (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final max = TextEditingController(text: "4");
    addTearDown(max.dispose);
    await tester.pumpWidget(frame(Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MembershipRolloverFields(
          choice: 1,
          onChoice: (_) {},
          maxController: max,
        ),
        const SizedBox(height: 16),
        const BtnGold(full: true, onPressed: _noop, child: Text("Save plan")),
        const SizedBox(height: 16),
        MembershipApplyButton(applying: false, onPressed: _noop),
      ],
    )));

    expect(find.text("Max unused rollover visits"), findsOneWidget);
    expect(find.text("How many unused sessions roll over. 0 means none."), findsOneWidget);
    expect(find.text("Apply to everyone on this membership"), findsOneWidget);
    expect(find.text("Roll over"), findsOneWidget);
    await save(tester, "membership_rollover_editor");
  });

  testWidgets("client profile shows a separate override for each membership", (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final month = isoToday().substring(0, 7);
    final ten = MembershipPlan(
      id: "ten",
      name: "Semi-Private 10",
      kind: PlanKind.membership,
      maxSessions: 10,
      rolloverEnabled: true,
      rolloverMaxVisits: 4,
    );
    final sixteen = MembershipPlan(
      id: "sixteen",
      name: "Semi-Private 16",
      kind: PlanKind.membership,
      maxSessions: 16,
      rolloverEnabled: true,
      rolloverMaxVisits: 6,
    );
    final info = ClientInfo(
      id: "c1",
      name: "Avery",
      membershipPlanId: "ten",
      plans: [
        ClientPlanEnrollment(
          planId: "ten",
          status: "active",
          startDate: "2026-06-01",
          maxSessionsOverride: 12,
          maxSessionsOverrideMonth: month,
          rolloverMaxOverride: 2,
        ),
        const ClientPlanEnrollment(
          planId: "sixteen",
          status: "active",
          startDate: "2026-09-01",
        ),
      ],
    );

    await tester.pumpWidget(frame(PlanAllowances(
      info: info,
      plans: [ten, sixteen],
      bookings: const [],
      onChanged: (_) {},
    )));

    expect(find.text("SEMI-PRIVATE 10"), findsOneWidget);
    expect(find.text("SEMI-PRIVATE 16"), findsOneWidget);
    expect(find.text("This client only"), findsNWidgets(2));
    expect(find.textContaining("only for Semi-Private 10"), findsOneWidget);
    expect(find.textContaining("only for Semi-Private 16"), findsOneWidget);
    await save(tester, "client_plan_overrides");
  });
}

void _noop() {}
