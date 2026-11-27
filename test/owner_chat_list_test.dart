import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/owner_inbox.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/widgets/owner_chat_list.dart";

void main() {
  testWidgets("owner chat list mockup", (tester) async {
    if (!File(_interRegular).existsSync()) return;
    await _loadUiFont();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppColors.apply(AppPalette.dark);
    final now = DateTime(2026, 11, 21, 16);
    final base = AppTheme.current;
    const name = "owner-chat-list";
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: "Inter"),
        primaryTextTheme: base.primaryTextTheme.apply(fontFamily: "Inter"),
      ),
      home: Scaffold(
        backgroundColor: AppColors.bg,
        body: RepaintBoundary(
          key: const Key(name),
          child: ColoredBox(
            color: AppColors.bg,
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontFamily: "Inter", decoration: TextDecoration.none),
              child: Column(
                children: [
                  const SizedBox(height: 36),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: () {},
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.gold,
                          side: BorderSide(color: AppColors.goldDim),
                        ),
                        child: const Text(
                          "Contact ONE Fitness",
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFamily: "Inter"),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _exampleList(now)),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text("All coaches"), findsOneWidget);
    expect(find.text("Coach Chris"), findsWidgets);
    expect(find.text("ONE Fitness Marketplace (business)"), findsOneWidget);
    expect(find.text("Alex Rivera"), findsOneWidget);
    expect(find.text("ONE Fitness"), findsOneWidget);
    expect(find.text(kTeamChatLabel), findsOneWidget);
    expect(find.text("Search by client name"), findsOneWidget);

    await expectLater(find.byKey(const Key(name)), matchesGoldenFile("goldens/$name.png"));
    final golden = File("test/goldens/$name.png");
    final copy = File("/opt/cursor/artifacts/owner-chat-list.png");
    if (golden.existsSync()) {
      copy.parent.createSync(recursive: true);
      golden.copySync(copy.path);
    }
  });
}

Widget _exampleList(DateTime now) {
  return OwnerChatList(
    now: now,
    selectedKey: kOwnerFilterAll,
    filters: const [
      OwnerCoachOption(key: kOwnerFilterAll, label: "All coaches"),
      OwnerCoachOption(key: "avery", label: "Coach Avery"),
      OwnerCoachOption(key: "chris", label: "Coach Chris"),
      OwnerCoachOption(key: kOwnerBusinessKey, label: kOneFitnessBusinessLabel),
    ],
    onFilter: (_) {},
    onOpen: (_) {},
    onNewChat: () {},
    onNewBroadcast: () {},
    rows: [
      OwnerInboxRow(
        id: "client:alex:chris",
        clientId: "alex",
        coachKey: "chris",
        title: "Alex Rivera",
        coachLabel: "Coach Chris",
        preview: "See you at 6.",
        at: DateTime(2026, 11, 21, 15, 40),
        unread: true,
      ),
      OwnerInboxRow(
        id: "client:jordan:business",
        clientId: "jordan",
        coachKey: kOwnerBusinessKey,
        title: "Jordan Lee",
        coachLabel: kOneFitnessLabel,
        preview: "Got your text about tomorrow.",
        at: DateTime(2026, 11, 21, 14, 15),
        unread: false,
        outgoing: true,
      ),
      OwnerInboxRow(
        id: "client:sam:avery",
        clientId: "sam",
        coachKey: "avery",
        title: "Sam Patel",
        coachLabel: "Coach Avery",
        preview: "Your new program is in.",
        at: DateTime(2026, 11, 20, 9),
        unread: false,
        outgoing: true,
      ),
      OwnerInboxRow(
        id: "pair:avery:chris",
        clientId: null,
        coachKey: "pair:avery:chris",
        title: "Coach Avery ↔ Coach Chris",
        coachLabel: kTeamChatLabel,
        preview: "Can you cover my 5?",
        at: DateTime(2026, 11, 16, 11),
        unread: true,
        team: true,
        participantIds: const {"avery", "chris"},
      ),
    ],
  );
}

const _interRegular = "/usr/share/fonts/truetype/macos/Inter-Regular.ttf";

Future<void> _loadUiFont() async {
  final inter = FontLoader("Inter");
  final interBytes = File("/usr/share/fonts/truetype/macos/Inter-Bold.ttf").readAsBytesSync();
  inter.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(interBytes))));
  await inter.load();
  final iconPath = _lucideFontPath();
  if (iconPath == null) return;
  final icons = FontLoader("packages/lucide_flutter/LucideIcons");
  final iconBytes = File(iconPath).readAsBytesSync();
  icons.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(iconBytes))));
  await icons.load();
}

String? _lucideFontPath() {
  final config = File(".dart_tool/package_config.json");
  if (!config.existsSync()) return null;
  final json = jsonDecode(config.readAsStringSync());
  final packages = json["packages"];
  if (packages is! List) return null;
  for (final pkg in packages) {
    if (pkg is! Map || pkg["name"] != "lucide_flutter") continue;
    final root = pkg["rootUri"];
    if (root is! String) return null;
    final dir = Directory.fromUri(config.parent.uri.resolve(root));
    final font = File("${dir.path}/assets/lucide.ttf");
    if (font.existsSync()) return font.path;
  }
  return null;
}
