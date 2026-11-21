import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/legal/sms_consent.dart";
import "package:onefitness/core/legal/sms_opt_in_prompt.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/utils/coach_names.dart";
import "package:onefitness/features/client/sms/sms_opt_in_prompt.dart";
import "package:onefitness/features/trainer/dashboard/sms_opt_in_ask_card.dart";

void main() {
  final now = DateTime.utc(2026, 11, 21, 15);

  group("who sees the prompt", () {
    test("false and null both still need a yes", () {
      expect(_show(smsOptIn: false, now: now), isTrue);
      expect(_show(smsOptIn: null, now: now), isTrue);
    });

    test("a client who already agreed does not see it", () {
      expect(_show(smsOptIn: true, now: now), isFalse);
    });

    test("someone who opted out does not see it, even from a push", () {
      expect(_show(smsOptIn: false, optedOut: true, now: now), isFalse);
      expect(_show(smsOptIn: null, optedOut: true, now: now, fromPush: true), isFalse);
      expect(_show(smsOptIn: true, optedOut: true, now: now, fromPush: true), isFalse);
    });

    test("Not now hides it for 14 days, and a tapped push still opens it", () {
      final until = smsOptInHiddenUntil(now);
      expect(until.difference(now), const Duration(days: kSmsOptInSnoozeDays));
      expect(_show(smsOptIn: null, now: now.add(const Duration(days: 13)), hiddenUntil: until), isFalse);
      expect(_show(smsOptIn: false, now: until, hiddenUntil: until), isTrue);
      expect(
        _show(smsOptIn: null, now: now, hiddenUntil: until, fromPush: true),
        isTrue,
      );
    });

    test("coach assignment never decides it", () {
      const withCoach = SmsPromptPerson(
        id: "with-coach",
        smsOptIn: null,
        smsOptedOut: false,
        primaryTrainerId: "coach-1",
      );
      const noCoach = SmsPromptPerson(
        id: "no-coach",
        smsOptIn: false,
        smsOptedOut: false,
      );
      const optedOut = SmsPromptPerson(
        id: "stopped",
        smsOptIn: false,
        smsOptedOut: true,
        primaryTrainerId: "coach-1",
      );
      const agreed = SmsPromptPerson(
        id: "agreed",
        smsOptIn: true,
        smsOptedOut: false,
      );
      expect(
        smsOptInPromptRecipientIds([withCoach, noCoach, optedOut, agreed, const SmsPromptPerson(id: "", smsOptIn: null, smsOptedOut: false)]),
        ["with-coach", "no-coach"],
      );
    });
  });

  group("what gets stored and what gets pushed", () {
    test("Yes stores the same sentences the prompt shows", () {
      final record = smsConsentRecord();
      expect(record, contains(kSmsConsentLabel));
      expect(record, contains(kSmsConsentDisclosure));
      expect(record, contains("Consent is not required to buy"));
      expect(record, contains("(v$kSmsConsentVersion)"));
    });

    test("the push is in-app only and deep-links to the prompt", () {
      final push = smsOptInOwnerPush();
      expect(push["title"], kSmsOptInPushTitle);
      expect(push["sms"], isFalse);
      final data = push["data"] as Map<String, String>;
      expect(smsOptInPushOpensPrompt(data), isTrue);
      expect(data["screen"], "dashboard");
    });

    test("clients only see coach wording", () {
      final shown = "$kSmsOptInPromptTitle $kSmsOptInPushTitle $kSmsConsentLabel $kSmsConsentDisclosure";
      expect(shown, contains("your coach"));
      expect(
        exposesLegalCoachName(shown: shown, legalName: "Jane Smith", coachName: "Coach Chris"),
        isFalse,
      );
      expect(shown.toLowerCase().contains("owner"), isFalse);
    });

    test("the owner function never texts and does not look at the coach", () {
      final src = File("supabase/functions/prompt-sms-opt-in/index.ts").readAsStringSync() +
          File("supabase/functions/_shared/smsOptInPrompt.ts").readAsStringSync();
      expect(src.contains("sendSms"), isFalse);
      expect(src.contains("smsClientIfOptedIn"), isFalse);
      expect(src.contains("primary_trainer_id"), isFalse);
      expect(src.contains(kSmsOptInPushTitle), isTrue);
      expect(src.contains('kind: "sms-opt-in"'), isTrue);
      expect(src.contains('role !== "owner"'), isTrue);
    });

    test("nothing sends the prompt when the app opens", () {
      final bootstrap = File("lib/data/providers/supabase_bootstrap_provider.dart").readAsStringSync();
      final main = File("lib/main.dart").readAsStringSync();
      expect(bootstrap.contains("promptSmsOptIn"), isFalse);
      expect(main.contains("promptSmsOptIn"), isFalse);
      expect(bootstrap.contains("smsOptInPushOpensPrompt"), isTrue);
    });
  });

  testWidgets("the prompt shows the consent and both choices", (tester) async {
    var yes = 0;
    var later = 0;
    await tester.pumpWidget(_app(SmsOptInPromptCard(
      onYes: () => yes++,
      onNotNow: () => later++,
    )));
    expect(find.text(kSmsOptInPromptTitle), findsOneWidget);
    expect(find.text(kSmsConsentLabel), findsOneWidget);
    expect(find.text(kSmsConsentDisclosure), findsOneWidget);
    expect(find.textContaining("Consent is not required to buy"), findsOneWidget);
    await tester.tap(find.text(kSmsOptInPromptYes));
    await tester.pump();
    expect(yes, 1);
    expect(later, 0);
    await tester.tap(find.text(kSmsOptInPromptLater));
    await tester.pump();
    expect(later, 1);
  });

  testWidgets("the owner button waits for a tap", (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(SmsOptInAskCard(
      onSend: () async {
        calls++;
        return {"sent": 3, "clients": 22};
      },
    )));
    expect(calls, 0);
    expect(find.textContaining("does not text them"), findsOneWidget);
    await tester.tap(find.text("Ask clients about texts"));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text("Notified 3 phones. 22 clients can open the prompt."), findsOneWidget);
  });

  testWidgets("dashboard card mockup", (tester) async {
    if (!File(_interRegular).existsSync()) return;
    await _shot(
      tester,
      name: "sms-opt-in-dashboard-card",
      child: const _DashboardMock(),
    );
  });

  testWidgets("sheet mockup", (tester) async {
    if (!File(_interRegular).existsSync()) return;
    await _shot(
      tester,
      name: "sms-opt-in-sheet",
      child: const _SheetMock(),
    );
  });
}

const _interRegular = "/usr/share/fonts/truetype/macos/Inter-Regular.ttf";

Future<void> _loadUiFont(WidgetTester tester) async {
  final loader = FontLoader("Inter");
  final bytes = File("/usr/share/fonts/truetype/macos/Inter-Bold.ttf").readAsBytesSync();
  loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  await loader.load();
}

bool _show({
  required bool? smsOptIn,
  required DateTime now,
  bool optedOut = false,
  DateTime? hiddenUntil,
  bool fromPush = false,
}) {
  return showSmsOptInPrompt(
    smsOptIn: smsOptIn,
    smsOptedOut: optedOut,
    hiddenUntil: hiddenUntil,
    now: now,
    openedFromPush: fromPush,
  );
}

Widget _app(Widget child) {
  AppColors.apply(AppPalette.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.current,
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: child,
      ),
    ),
  );
}

Future<void> _shot(WidgetTester tester, {required String name, required Widget child}) async {
  await _loadUiFont(tester);
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  AppColors.apply(AppPalette.dark);
  final base = AppTheme.current;
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: "Inter"),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: "Inter"),
    ),
    home: RepaintBoundary(
      key: Key(name),
      child: ColoredBox(
        color: AppColors.bg,
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontFamily: "Inter"),
          child: child,
        ),
      ),
    ),
  ));
  await tester.pump();
  await expectLater(find.byKey(Key(name)), matchesGoldenFile("goldens/$name.png"));
}

class _DashboardMock extends StatelessWidget {
  const _DashboardMock();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 56, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Hey Alex, it's a rest day",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.txt),
          ),
          const SizedBox(height: 8),
          Text("Saturday, Nov 21", style: TextStyle(fontSize: 13, color: AppColors.mute)),
          const SizedBox(height: 16),
          SmsOptInPromptCard(onYes: () {}, onNotNow: () {}, fontFamily: "Inter"),
        ],
      ),
    );
  }
}

class _SheetMock extends StatelessWidget {
  const _SheetMock();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 56, 18, 24),
          child: Opacity(
            opacity: 0.35,
            child: Text(
              "Hey Alex, it's a rest day",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.txt),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(top: BorderSide(color: AppColors.line)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(4)),
                ),
                SmsOptInPromptBody(onYes: () {}, onNotNow: () {}, fontFamily: "Inter"),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
