import "dart:io";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/privacy/client_contact_privacy.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/widgets/billing_address_form.dart";
import "package:onefitness/core/widgets/widgets.dart";
import "package:onefitness/data/models/billing_address.dart";
import "package:onefitness/data/models/saved_payment_method.dart";
import "package:onefitness/features/client/drawer_screens/payment_method_views.dart";
import "package:onefitness/features/trainer/clients/coach_private_fields.dart";

const sample = BillingAddress(
  name: "Sample Client A",
  line1: "100 Main St",
  line2: "Apt 4",
  city: "Burbank",
  state: "CA",
  postalCode: "91502",
);

const methods = [
  SavedPaymentMethod(id: "pm_card", type: "card", brand: "visa", last4: "4242", expMonth: 12, expYear: 2028, isDefault: true),
  SavedPaymentMethod(id: "ba_bank", type: "bank", brand: "Bank of Example", last4: "6789"),
];

Future<void> _loadFace(String family, List<String> paths) async {
  final existing = paths.where((path) => File(path).existsSync()).toList();
  if (existing.isEmpty) return;
  final loader = FontLoader(family);
  for (final path in existing) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const regular = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf";
  const bold = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf";
  // Body text uses Liberation Sans. Button labels leave the family unset, and
  // the test harness draws that as Ahem boxes, so the same faces are also
  // registered under Ahem.
  await _loadFace("LiberationSans", [regular, bold]);
  await _loadFace("Ahem", [regular, bold]);
  await _loadFace("Roboto", [regular, bold]);
  await _loadFace("MaterialIcons", [
    "/home/ubuntu/flutter-sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf",
  ]);
  await _loadFace("LucideIcons", [
    "/home/ubuntu/.pub-cache/hosted/pub.dev/lucide_flutter-1.25.0/assets/lucide.ttf",
  ]);
  await _loadFace("packages/lucide_flutter/LucideIcons", [
    "/home/ubuntu/.pub-cache/hosted/pub.dev/lucide_flutter-1.25.0/assets/lucide.ttf",
  ]);
}

Widget _phone(Widget child) {
  final base = AppTheme.themeFor(ThemeMode.dark, Brightness.dark);
  return MaterialApp(
    theme: base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: "LiberationSans"),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: "LiberationSans"),
    ),
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: RepaintBoundary(
        child: SizedBox(width: 390, height: 844, child: child),
      ),
    ),
  );
}

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
  final dir = Directory("/opt/cursor/artifacts");
  dir.createSync(recursive: true);
  File("${dir.path}/$name.png").writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  setUpAll(_loadFonts);

  test("the migration keeps the full address off a coach select", () {
    final sql = File("supabase/migrations/20261121150000_coach_billing_address_lock.sql").readAsStringSync();
    expect(sql, contains("client_billing_locality"));
    expect(sql, contains("revoke select (billing_address)"));
    expect(sql, contains("A billing address is already on file."));
    expect(sql, contains("coach_first_address"));
    expect(sql.contains("grant select (billing_address)"), isFalse);

    final save = File("supabase/functions/save-billing-address/index.ts").readAsStringSync();
    expect(save, contains("A billing address is already on file."));
    expect(save, contains('role === "coach"'));
  });

  testWidgets("the client payment screen keeps the address with the card", (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final access = billingAccessFor(viewer: BillingViewer.client, onFile: true, full: sample);
    await tester.pumpWidget(_phone(PaymentMethodScreenView(
      title: "Payment Details",
      onBack: () {},
      access: access,
      addressLoading: false,
      methods: methods,
      methodsLoading: false,
      onAdd: () {},
      onEditAddress: () {},
      onRemove: (_) {},
    )));

    expect(find.text("Add payment method"), findsOneWidget);
    expect(find.text("Billing address"), findsOneWidget);
    expect(find.textContaining("100 Main St"), findsOneWidget);
    expect(find.textContaining("Apt 4"), findsOneWidget);
    expect(find.text("Visa •••• 4242"), findsOneWidget);
    expect(find.text("Add card"), findsNothing);
    await _shoot(tester, "payment-method-screen");
  });

  testWidgets("step 1 is the billing address, prefilled", (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_phone(BillingAddressStepView(
      viewer: BillingViewer.client,
      onFile: true,
      address: sample,
      clientName: "Sample Client A",
      onBack: () {},
      onContinue: () {},
      onChanged: (_) {},
    )));
    await tester.pump();

    expect(find.text("Step 1 of 2"), findsOneWidget);
    expect(find.text("Billing address"), findsOneWidget);
    expect(find.text("Sample Client A"), findsOneWidget);
    expect(find.text("100 Main St"), findsOneWidget);
    expect(find.text("Apt 4"), findsOneWidget);
    expect(find.text("91502"), findsOneWidget);
    expect(find.text("Continue"), findsOneWidget);
    await _shoot(tester, "add-payment-step-1-address");
  });

  testWidgets("step 2 is card or bank, after the address", (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_phone(CardEntryStepView(
      addressSummary: formatBillingAddress(sample),
      bank: false,
      onBack: () {},
      onPickCard: () {},
      onPickBank: () {},
      onContinue: () {},
    )));

    expect(find.text("Step 2 of 2"), findsOneWidget);
    expect(find.text("Card"), findsOneWidget);
    expect(find.text("Bank account"), findsOneWidget);
    expect(find.text("Enter card"), findsOneWidget);
    expect(find.textContaining("100 Main St"), findsOneWidget);
    await _shoot(tester, "add-payment-step-2-card");
  });

  testWidgets("the owner edit profile shows the full address and Edit", (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final access = billingAccessFor(viewer: BillingViewer.owner, onFile: true, full: sample);
    await tester.pumpWidget(_phone(ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const BackBar(onBack: null, title: "Profile"),
        const SizedBox(height: 10),
        const SectionLabel("Edit Profile"),
        const FieldLabeled(label: "Name", child: Text("Sample Client A")),
        const SizedBox(height: 14),
        BillingAddressPanel(access: access, onEdit: () {}),
      ],
    )));

    expect(find.text("EDIT PROFILE"), findsOneWidget);
    expect(find.textContaining("100 Main St"), findsOneWidget);
    expect(find.textContaining("91502"), findsOneWidget);
    expect(find.text("Edit"), findsOneWidget);
    expect(find.text("Update"), findsNothing);
    await _shoot(tester, "owner-edit-profile-billing");
  });

  testWidgets("a coach with an address on file sees city and state only", (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final access = billingAccessFor(
      viewer: BillingViewer.coach,
      onFile: true,
      full: sample,
      city: "Burbank",
      state: "CA",
    );
    await tester.pumpWidget(_phone(ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const BackBar(onBack: null, title: "Profile"),
        const SizedBox(height: 10),
        const SectionLabel("Edit Profile"),
        Text("Phone", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text("On file", style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const BtnGhost(onPressed: null, child: Text("Update")),
        const SizedBox(height: 14),
        BillingAddressPanel(access: access),
      ],
    )));

    expect(find.text("Burbank, CA"), findsOneWidget);
    expect(find.text("100 Main St"), findsNothing);
    expect(find.text("Apt 4"), findsNothing);
    expect(find.text("91502"), findsNothing);
    expect(find.text("Sample Client A"), findsNothing);
    expect(find.text("Update"), findsOneWidget);
    expect(find.text("Add"), findsNothing);
    await _shoot(tester, "coach-billing-city-state");
  });
}
