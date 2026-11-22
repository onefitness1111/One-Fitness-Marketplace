import "dart:io";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/widgets/widgets.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/membership_plan.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/clients/purchase_for_client_section.dart";
import "package:onefitness/features/trainer/memberships/manage_memberships_screen.dart";

Future<void> _loadRoboto() async {
  final base = "${Platform.environment["HOME"]}/flutter/bin/cache/artifacts/material_fonts";
  if (!File("$base/Roboto-Regular.ttf").existsSync()) return;
  final loader = FontLoader("Roboto");
  for (final name in ["Roboto-Regular.ttf", "Roboto-Medium.ttf", "Roboto-Bold.ttf"]) {
    final bytes = await File("$base/$name").readAsBytes();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await loader.load();
  final lucide = File("${Platform.environment["HOME"]}/.pub-cache/hosted/pub.dev/lucide_flutter-1.25.0/assets/lucide.ttf");
  if (lucide.existsSync()) {
    final icons = FontLoader("LucideIcons");
    icons.addFont(Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(await lucide.readAsBytes()))));
    await icons.load();
  }
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

  MembershipPlan sample(String id, String name, PlanStatus status, {PlanKind kind = PlanKind.membership, int cents = 22900}) =>
      MembershipPlan(
        id: id,
        name: name,
        kind: kind,
        status: status,
        priceCents: cents,
        maxSessions: 12,
        category: kind == PlanKind.package ? "One-on-One Pack" : "Semi-Private Membership",
      );

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
              child: ColoredBox(color: AppColors.bg, child: child),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets("Access Hub shows Active, Ghost, and Archived", (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(membershipPlansProvider.notifier).setAll([
      sample("a", "12 Semi-Private", PlanStatus.active),
      sample("g", "8 One-on-One Legacy", PlanStatus.ghost, kind: PlanKind.package, cents: 64000),
      sample("z", "Old Unlimited", PlanStatus.archived),
    ]);
    container.read(packageCategoriesProvider.notifier).setAll(["Semi-Private Membership", "One-on-One Pack"]);
    container.read(trainerRosterProvider.notifier).setAll(const []);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: frame(const ManageMembershipsScreen()),
    ));
    await tester.pump();

    expect(find.byKey(const Key("plan-status-tabs")), findsOneWidget);
    expect(find.text("Active"), findsWidgets);
    expect(find.text("Ghost"), findsWidgets);
    expect(find.text("Archived"), findsWidgets);
    expect(find.text("12 Semi-Private"), findsOneWidget);
    expect(find.text("8 One-on-One Legacy"), findsNothing);

    await tester.tap(find.text("Ghost"));
    await tester.pumpAndSettle();
    expect(find.text("8 One-on-One Legacy"), findsOneWidget);
    expect(find.text("Ghost"), findsWidgets);
    expect(find.text("12 Semi-Private"), findsNothing);

    await save(tester, "access-hub-ghost-tab");
  });

  testWidgets("staff enroll picker labels a ghost plan", (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(membershipPlansProvider.notifier).setAll([
      sample("a", "12 Semi-Private", PlanStatus.active),
      sample("g", "8 One-on-One Legacy", PlanStatus.ghost, kind: PlanKind.package, cents: 64000),
      sample("z", "Old Unlimited", PlanStatus.archived, cents: 19900),
    ]);
    container.read(packageCategoriesProvider.notifier).setAll(["Semi-Private Membership", "One-on-One Pack"]);
    container.read(trainerAuthProvider.notifier).signIn("owner");

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: frame(PurchaseForClientSection(
        info: const ClientInfo(id: "c1", name: "Avery Cole"),
        onBack: () {},
        onPlanAssigned: (_) {},
      )),
    ));
    await tester.pump();

    expect(find.text("8 One-on-One Legacy"), findsOneWidget);
    expect(find.text("Ghost"), findsOneWidget);
    expect(find.text("Old Unlimited"), findsNothing);
    expect(find.text("12 Semi-Private"), findsOneWidget);

    await save(tester, "staff-enroll-ghost-plan");
  });
}
