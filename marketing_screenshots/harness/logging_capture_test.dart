import "dart:convert";
import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:supabase_flutter/supabase_flutter.dart";

import "package:onefitness/core/theme/palette_scope.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/core/utils/merge_token_utils.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/exercise_prescription.dart";
import "package:onefitness/data/models/food_log.dart";
import "package:onefitness/data/models/intake_schema.dart";
import "package:onefitness/data/models/membership_plan.dart";
import "package:onefitness/data/models/nutrition_plan.dart";
import "package:onefitness/data/models/program_day.dart";
import "package:onefitness/data/models/saved_program.dart";
import "package:onefitness/data/models/signature.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/data/models/waiver_doc.dart";
import "package:onefitness/data/models/workout_log.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/platform_settings_provider.dart";
import "package:onefitness/data/providers/theme_mode_provider.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/client/shell/client_shell.dart";
import "package:onefitness/features/client/shell/client_shell_state.dart";
import "package:onefitness/features/shared/session_logger_view.dart";

/// Nutrition and workout logging shots. Prints TAP lines: file, label, x, y
/// in pixels on the 1290x2796 image.

const _shotKey = Key("marketing-shot");

const _plan = MembershipPlan(
  id: "semiprivate-membership",
  name: "Semi-Private Membership",
  kind: PlanKind.membership,
  maxSessions: 12,
  allowedTypes: ["semi-private"],
  priceCents: 22900,
);

const _waiverBody = "Sample waiver for screenshots.";

final _signed = SignedDocument(
  id: "sig-tina",
  docId: "signup-waiver",
  title: "General Liability Waiver",
  signedAt: "2026-11-01T18:00:00.000Z",
  documentVersionHash: documentVersionHash(_waiverBody),
);

final _tina = ClientInfo(
  id: "tina",
  name: "Tina Alvarez",
  email: "tina@example.com",
  phone: "18185550119",
  city: "North Hollywood",
  state: "CA",
  birthday: "1992-03-14",
  membershipPlanId: "semiprivate-membership",
  primaryTrainerId: "coach-will",
  plans: [
    ClientPlanEnrollment(planId: "semiprivate-membership", status: "active", startDate: "2026-10-01"),
  ],
);

final _will = Trainer(
  id: "coach-will",
  name: "Coach Will",
  coachName: "Coach Will",
  locationName: "ONE Fitness",
  locationAddress: "11300 Magnolia Blvd, North Hollywood, CA",
);

final _pushDay = ProgramDay(
  id: "push",
  title: "Push Day",
  exercises: const [
    ExercisePrescription(id: "sq", name: "Back Squat", group: "legs", sets: 3, reps: 8, weight: "135", rest: "120s"),
    ExercisePrescription(id: "bp", name: "Bench Press", group: "chest", sets: 3, reps: 8, weight: "95", rest: "120s"),
    ExercisePrescription(id: "row", name: "Barbell Row", group: "back", sets: 3, reps: 10, weight: "85", rest: "90s"),
  ],
);

SavedProgram _program() => SavedProgram(
      id: "prog-push",
      name: "Strength with Coach Will",
      status: "active",
      coachName: "Coach Will",
      programDays: [_pushDay],
    );

NutritionPlan _nutrition() => const NutritionPlan(
      trainingTargets: MacroTargets(calories: "2100", protein: "30", carbs: "40", fats: "30"),
      restTargets: MacroTargets(calories: "1800", protein: "30", carbs: "35", fats: "35"),
      mealBudgets: DaySplit(
        training: {"breakfast": "500", "lunch": "650", "dinner": "700", "snacks": "250", "smoothies": "0"},
        rest: {"breakfast": "400", "lunch": "550", "dinner": "600", "snacks": "250", "smoothies": "0"},
      ),
      breakfast: [
        NutritionMeal(id: "bf-yogurt", name: "Greek yogurt bowl", calories: 320, protein: 28, carbs: 32, fats: 8),
      ],
      lunch: [
        NutritionMeal(id: "lu-salad", name: "Grilled chicken salad", calories: 420, protein: 42, carbs: 18, fats: 16),
      ],
    );

ClientRecord _record({FoodLog? food, List<WorkoutLogEntry>? logs, bool withProgram = true}) {
  return ClientRecord(
    id: _tina.id,
    tourSeenDashboard: true,
    tourSeenDrawer: true,
    onboardingComplete: true,
    signatures: [_signed],
    intake: const {
      "personalTraining": IntakeRecord(completed: true),
      "nutritional": IntakeRecord(completed: true),
      "physical": IntakeRecord(completed: true),
    },
    nutrition: _nutrition(),
    foodLog: food ?? const FoodLog(),
    savedPrograms: withProgram ? [_program()] : const [],
    workoutLogs: logs ?? const [],
    loggedDates: logs == null ? const [] : [isoToday()],
  );
}

const _yogurt = FoodLogItem(
  id: "log-yogurt",
  name: "Plain Greek yogurt",
  qty: 1.5,
  unit: "cup",
  calories: 195,
  protein: 34.5,
  carbs: 13.5,
  fats: 1.5,
);

const _salad = FoodLogItem(
  id: "log-salad",
  name: "Grilled chicken salad",
  qty: 1,
  unit: "serving",
  calories: 420,
  protein: 42,
  carbs: 18,
  fats: 16,
);

FoodLog _loggedDay({bool salad = true}) {
  final date = foodLogDate(DateTime.now());
  return FoodLog(
    days: {
      date: {
        "breakfast": const [_yogurt],
        if (salad) "lunch": const [_salad],
      },
    },
    recents: salad ? const [_salad, _yogurt] : const [_yogurt],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _loadFonts();
    // A local client only, so reading the current user does not throw.
    // The URL is closed and is not the live project.
    await Supabase.initialize(
      url: "http://127.0.0.1:9",
      anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.dGVzdA",
    );
  });
  setUp(() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      if (text.contains("overflowed")) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  });

  testWidgets("nutrition logging steps", (tester) async {
    final container = await _boot(tester, _record());
    await _shot(tester, "nutrition/01_dashboard", find.text("Plans").last, "Plans");
    container.read(clientScreenProvider.notifier).go("plans");
    await _settle(tester);
    await _shot(tester, "nutrition/02_plans", find.text("Nutrition Program"), "Nutrition Program");
    await tester.tap(find.text("Nutrition Program"));
    await _settle(tester);
    await tester.ensureVisible(find.text("FOOD LOG"));
    await _settle(tester);
    await _shot(tester, "nutrition/03_food_log", find.text("Search").first, "Search");
    await tester.tap(find.text("Search").first);
    await _settle(tester);
    await tester.enterText(find.byType(TextField).first, "yogurt");
    await _settle(tester);
    await tester.tap(find.textContaining("Plain Greek yogurt"));
    await _settle(tester);
    final qty = find.byType(TextField).last;
    await tester.enterText(qty, "1.5");
    FocusManager.instance.primaryFocus?.unfocus();
    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester);
    await _shot(tester, "nutrition/04_search_portion", find.text("Log"), "Log");
    // Log writes through Supabase. Close the sheet and show the saved row
    // from stubbed data instead of calling the network.
    Navigator.of(tester.element(find.text("Log"))).pop();
    await _settle(tester);
    container.read(clientRecordProvider.notifier).update((r) => r.copyWith(foodLog: _loggedDay(salad: false)));
    await _settle(tester);
    await tester.ensureVisible(find.textContaining("of 2100 kcal"));
    await _settle(tester);
    final lunchQuickAdd = find.text("Quick add").at(1);
    await _shot(tester, "nutrition/05_yogurt_logged", lunchQuickAdd, "Quick add");
    await tester.tap(lunchQuickAdd);
    await _settle(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), "Grilled chicken salad");
    await tester.enterText(fields.at(1), "420");
    await tester.enterText(fields.at(2), "42");
    await tester.enterText(fields.at(3), "18");
    await tester.enterText(fields.at(4), "16");
    FocusManager.instance.primaryFocus?.unfocus();
    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester);
    await _shot(tester, "nutrition/06_quick_add_macros", find.text("Log"), "Log");
    Navigator.of(tester.element(find.text("Log").last)).pop();
    await _settle(tester);
    container.read(clientRecordProvider.notifier).update((r) => r.copyWith(foodLog: _loggedDay()));
    await _settle(tester);
    await tester.ensureVisible(find.textContaining("of 2100 kcal"));
    await _settle(tester);
    await _shot(tester, "nutrition/07_day_summary", find.text("NO_NEXT"), "none");
    await _end(tester);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("workout logging steps", (tester) async {
    final container = await _boot(tester, _record());
    await _shot(tester, "workout/01_dashboard", find.text("Plans").last, "Plans");
    container.read(clientScreenProvider.notifier).go("plans");
    await _settle(tester);
    await tester.ensureVisible(find.text("Start workout"));
    await _shot(tester, "workout/02_program", find.text("Start workout"), "Start workout");

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _logger(tester, _record(), initialDay: null);
    await tester.tap(find.text("Start workout"));
    await _settle(tester);
    await _fillSets(tester, reps: "8", weight: "135");
    await tester.ensureVisible(find.text("Next"));
    await _settle(tester);
    await _shot(tester, "workout/03_log_squat", find.text("Next"), "Next");
    await tester.tap(find.text("Next"));
    await _settle(tester);
    await _fillSets(tester, reps: "8", weight: "95");
    await tester.ensureVisible(find.text("Save session log"));
    await _settle(tester);
    await _shot(tester, "workout/04_log_bench", find.text("Save session log"), "Save session log");
    await tester.tap(find.text("Save session log"));
    await _settle(tester);
    await _shot(tester, "workout/05_session_logged", find.text("Back to Days"), "Back to Days");

    final done = WorkoutLogEntry(
      id: "log-push",
      date: isoToday(),
      programId: "prog-push",
      programName: "Strength with Coach Will",
      dayId: "push",
      dayTitle: "Push Day",
      loggedBy: "client",
      loggedByName: "Tina Alvarez",
      exercises: const [
        LoggedExercise(
          name: "Back Squat",
          sets: [
            LoggedSet(setNum: 1, targetReps: 8, completedReps: 8, completedWeight: 135, completed: true),
            LoggedSet(setNum: 2, targetReps: 8, completedReps: 8, completedWeight: 135, completed: true),
            LoggedSet(setNum: 3, targetReps: 8, completedReps: 8, completedWeight: 135, completed: true),
          ],
        ),
        LoggedExercise(
          name: "Bench Press",
          sets: [
            LoggedSet(setNum: 1, targetReps: 8, completedReps: 8, completedWeight: 95, completed: true),
            LoggedSet(setNum: 2, targetReps: 8, completedReps: 8, completedWeight: 95, completed: true),
            LoggedSet(setNum: 3, targetReps: 8, completedReps: 8, completedWeight: 95, completed: true),
          ],
        ),
      ],
    );
    // Back to Days returns to this program. History is a menu item, so the
    // next tap on this screen is the menu, then History.
    final back = await _boot(tester, _record(logs: [done]));
    back.read(clientScreenProvider.notifier).go("plans");
    await _settle(tester);
    await tester.ensureVisible(find.text("Start workout"));
    final menu = find.byIcon(LucideIcons.menu);
    await _shot(tester, "workout/06_back_to_program", menu, "menu");
    await tester.tap(menu);
    await _settle(tester);
    await _shot(tester, "workout/07_menu", find.text("History"), "History");
    await tester.tap(find.text("History"));
    await _settle(tester);
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    if (scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      await _settle(tester);
    }
    await _shot(tester, "workout/08_history", find.text("Push Day"), "Push Day");
    await tester.tap(find.text("Push Day"));
    await _settle(tester);
    await _shot(tester, "workout/09_history_sets", find.text("NO_NEXT"), "none");
    await _end(tester);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _fillSets(WidgetTester tester, {required String reps, required String weight}) async {
  final fields = find.byType(TextField);
  expect(fields, findsAtLeastNWidgets(6));
  for (var i = 0; i < 3; i++) {
    await tester.enterText(fields.at(i), reps);
  }
  for (var i = 3; i < 6; i++) {
    await tester.enterText(fields.at(i), weight);
  }
  FocusManager.instance.primaryFocus?.unfocus();
  tester.view.viewInsets = FakeViewPadding.zero;
  await _settle(tester);
}

Future<void> _logger(WidgetTester tester, ClientRecord record, {String? initialDay}) async {
  _phone(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [initialThemeModeProvider.overrideWithValue(ThemeMode.light)],
        child: PaletteScope(
        builder: (context, theme) => RepaintBoundary(
          key: _shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: theme,
            home: Scaffold(
              body: SessionLoggerView(
                client: record,
                authorName: "Tina Alvarez",
                authorRole: "client",
                loggedBy: "client",
                liveSync: false,
                initialDayId: initialDay,
                onSave: (_) async {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<ProviderContainer> _boot(WidgetTester tester, ClientRecord record) async {
  final container = ProviderContainer(
    overrides: [initialThemeModeProvider.overrideWithValue(ThemeMode.light)],
  );
  addTearDown(container.dispose);
  container.read(clientInfoProvider.notifier).update((_) => _tina);
  container.read(clientRecordProvider.notifier).update((_) => record);
  container.read(trainersProvider.notifier).setAll([_will]);
  container.read(membershipPlansProvider.notifier).setAll(const [_plan]);
  container.read(waiversProvider.notifier).setAll(const [
    WaiverDoc(id: "signup-waiver", title: "General Liability Waiver", body: _waiverBody),
  ]);
  container.read(platformSettingsProvider.notifier).update(
        (s) => s.copyWith(
          businessName: "ONE Fitness Marketplace",
          locationName: "ONE Fitness",
          locationAddress: "11300 Magnolia Blvd, North Hollywood, CA",
        ),
      );
  _phone(tester);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: PaletteScope(
        builder: (context, theme) => RepaintBoundary(
          key: _shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: theme,
            home: const ClientShell(),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  if (find.text("Skip for now").evaluate().isNotEmpty) {
    await tester.tap(find.text("Skip for now"));
    await _settle(tester);
  }
  return container;
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1290, 2796);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewPadding = FakeViewPadding.zero;
  tester.view.viewInsets = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

/// The live workout view subscribes to Supabase realtime. Leaving that
/// screen schedules a one-shot disconnect. Advance past it so the test
/// binding does not still see a timer after the tree is gone.
Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  // 50s deferred disconnect, then a 6s socket-close timeout.
  await tester.pump(const Duration(seconds: 55));
  await tester.pump(const Duration(seconds: 12));
}

Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 8),
    );
  } catch (_) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _shot(WidgetTester tester, String name, Finder next, String label) async {
  await _settle(tester);
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final captured = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List();
    final file = File("marketing_screenshots/$name.png");
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return "${image.width}x${image.height}";
  });
  var tap = "none";
  if (next.evaluate().isNotEmpty) {
    final center = tester.getRect(next).center;
    tap = "${(center.dx * 3).round()},${(center.dy * 3).round()} $label";
  }
  // ignore: avoid_print
  print("TAP $name $tap");
  // ignore: avoid_print
  print("SHOT $name $captured");
}

Future<void> _loadFonts() async {
  final manifestJson = await rootBundle.loadString("FontManifest.json");
  final families = json.decode(manifestJson) as List<dynamic>;
  for (final raw in families) {
    final family = raw as Map<String, dynamic>;
    final loader = FontLoader(family["family"] as String);
    for (final font in family["fonts"] as List<dynamic>) {
      loader.addFont(rootBundle.load((font as Map<String, dynamic>)["asset"] as String));
    }
    await loader.load();
  }
  final dir = Directory("marketing_screenshots/fonts");
  final roboto = FontLoader("Roboto");
  for (final name in const [
    "Roboto-Light.ttf",
    "Roboto-Regular.ttf",
    "Roboto-Italic.ttf",
    "Roboto-Medium.ttf",
    "Roboto-MediumItalic.ttf",
    "Roboto-Bold.ttf",
    "Roboto-BoldItalic.ttf",
    "Roboto-Black.ttf",
  ]) {
    final bytes = await File("${dir.path}/$name").readAsBytes();
    roboto.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await roboto.load();
  final icons = FontLoader("MaterialIcons");
  final iconBytes = await File("${dir.path}/MaterialIcons-Regular.otf").readAsBytes();
  icons.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(iconBytes))));
  await icons.load();
}
