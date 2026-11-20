import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/legal/health_sources.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/widgets/source_citations.dart";
import "package:onefitness/data/models/food_log.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/features/client/plans/nutrition_tab.dart";

void main() {
  setUp(() => AppColors.apply(AppPalette.dark));

  Future<void> pumpTab(
    WidgetTester tester, {
    Size size = const Size(400, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: NutritionTab())),
      ),
    );
    await tester.pump();
  }

  int center(WidgetTester tester) {
    final text = tester.widget<Text>(
      find.byKey(const Key("calorie-ring-center")),
    );
    return int.parse(text.data!.replaceAll(",", ""));
  }

  testWidgets("five targets sit on one line at 320 width", (tester) async {
    await pumpTab(tester, size: const Size(320, 900));

    const labels = ["CAL", "PG", "CG", "FG", "H2O"];
    final tops = <double>[];
    for (final label in labels) {
      final found = find.text(label);
      expect(found, findsOneWidget, reason: label);
      final rect = tester.getRect(found);
      expect(rect.height, lessThan(16), reason: "$label wrapped");
      tops.add(rect.top);
    }
    for (final top in tops) {
      expect((top - tops.first).abs(), lessThan(1));
    }
    final row = tester.getRect(find.byKey(const Key("nutrition-targets")));
    expect(row.right, lessThanOrEqualTo(320));
    expect(row.left, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets("guidelines start collapsed and toggle open", (tester) async {
    await pumpTab(tester);

    expect(find.text("Tap to read ⌄"), findsOneWidget);
    expect(find.textContaining("Eat around your workout"), findsNothing);

    await tester.tap(find.text("Tap to read ⌄"));
    await tester.pump();
    expect(find.textContaining("Eat around your workout"), findsOneWidget);
    expect(find.text("Tap to read ⌄"), findsNothing);

    await tester.tap(find.text("GUIDELINES"));
    await tester.pump();
    expect(find.textContaining("Eat around your workout"), findsNothing);
    expect(find.text("Tap to read ⌄"), findsOneWidget);
  });

  testWidgets("the three-way toggle switches log, meals, and grocery", (
    tester,
  ) async {
    await pumpTab(tester, size: const Size(320, 1600));

    expect(find.text("Training"), findsNothing);
    expect(find.text("Rest"), findsNothing);
    expect(find.text("Training Day"), findsOneWidget);
    expect(find.text("Program details"), findsNothing);

    expect(find.text("Nothing logged"), findsWidgets);
    expect(find.text("750 kcal budget"), findsOneWidget);
    expect(find.byKey(const Key("calorie-ring-center")), findsOneWidget);
    expect(find.text("Eggs & Oatmeal"), findsNothing);
    expect(find.text("GROCERY LIST"), findsNothing);

    final selected = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key("nutrition-segment-log")),
        matching: find.text("Log food"),
      ),
    );
    expect(selected.style?.color, Colors.black);
    final fill = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byKey(const Key("nutrition-segment-log")),
            matching: find.byType(Container),
          ),
        )
        .firstWhere((c) => c.decoration is BoxDecoration);
    expect((fill.decoration as BoxDecoration).color, const Color(0xFFD9D9D9));

    await tester.ensureVisible(
      find.byKey(const Key("nutrition-segment-meals")),
    );
    await tester.tap(find.byKey(const Key("nutrition-segment-meals")));
    await tester.pump();
    expect(find.text("Eggs & Oatmeal"), findsOneWidget);
    expect(find.text("Nothing logged"), findsNothing);
    expect(find.byKey(const Key("calorie-ring-center")), findsNothing);
    expect(find.text("GROCERY LIST"), findsNothing);

    await tester.ensureVisible(
      find.byKey(const Key("nutrition-segment-grocery")),
    );
    await tester.tap(find.byKey(const Key("nutrition-segment-grocery")));
    await tester.pump();
    expect(find.text("GROCERY LIST"), findsOneWidget);
    expect(find.text("Whole eggs"), findsWidgets);
    expect(find.text("Eggs & Oatmeal"), findsNothing);
    expect(find.text("Nothing logged"), findsNothing);
  });

  testWidgets(
    "sources show the first two, then the rest, with the disclaimer always",
    (tester) async {
      await pumpTab(tester);

      expect(find.textContaining("Protein and Exercise"), findsOneWidget);
      expect(find.textContaining("Glycogen Metabolism"), findsOneWidget);
      expect(find.textContaining("Creatine"), findsNothing);
      expect(find.text("Show 3 more sources ⌄"), findsOneWidget);
      expect(find.textContaining("not medical"), findsOneWidget);

      await tester.ensureVisible(find.text("Show 3 more sources ⌄"));
      await tester.tap(find.text("Show 3 more sources ⌄"));
      await tester.pump();

      expect(find.textContaining("Creatine"), findsWidgets);
      expect(
        find.textContaining("Dietary Guidelines for Americans"),
        findsOneWidget,
      );
      expect(find.text("Show fewer ⌃"), findsOneWidget);
      expect(find.textContaining("not medical"), findsOneWidget);

      await tester.tap(find.text("Show fewer ⌃"));
      await tester.pump();
      expect(find.textContaining("Creatine"), findsNothing);
      expect(find.text("Show 3 more sources ⌄"), findsOneWidget);
    },
  );

  testWidgets("a citation block without a limit still shows every source", (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SourceCitations(
            sources: kNutritionSources,
            disclaimer: kNutritionDisclaimer,
          ),
        ),
      ),
    );
    expect(find.text("Show 3 more sources ⌄"), findsNothing);
    expect(find.textContaining("Creatine"), findsWidgets);
    expect(
      find.textContaining("Dietary Guidelines for Americans"),
      findsOneWidget,
    );
    expect(find.textContaining("not medical"), findsOneWidget);
  });

  testWidgets(
    "the calorie ring animates when food is logged and snaps on a new day",
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: NutritionTab())),
        ),
      );
      await tester.pump();
      expect(center(tester), 2500);
      expect(find.text("left"), findsOneWidget);
      expect(find.textContaining("Eaten 0 of 2,500 kcal"), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(center(tester), 2500);

      final today = foodLogDate(DateTime.now());
      container
          .read(clientRecordProvider.notifier)
          .update(
            (r) => r.copyWith(
              foodLog: r.foodLog.add(
                today,
                "breakfast",
                const FoodLogItem(
                  id: "log-1",
                  name: "Oats",
                  qty: 1,
                  unit: "bowl",
                  calories: 500,
                  protein: 20,
                  carbs: 60,
                  fats: 10,
                ),
              ),
            ),
          );
      await tester.pump();
      final atStart = center(tester);
      expect(atStart, greaterThan(2300));
      expect(atStart, lessThanOrEqualTo(2500));

      await tester.pump(const Duration(milliseconds: 400));
      final mid = center(tester);
      expect(mid, lessThan(atStart));
      expect(mid, greaterThan(2000));

      await tester.pump(const Duration(milliseconds: 500));
      expect(center(tester), 2000);
      expect(find.text("500 of 550 kcal · 1 item"), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(center(tester), 2500);
      await tester.pump(const Duration(milliseconds: 300));
      expect(center(tester), 2500);
    },
  );

  testWidgets("going over fills the ring and shows the extra in gray", (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: NutritionTab())),
      ),
    );
    await tester.pump();

    final today = foodLogDate(DateTime.now());
    container
        .read(clientRecordProvider.notifier)
        .update(
          (r) => r.copyWith(
            foodLog: r.foodLog.add(
              today,
              "dinner",
              const FoodLogItem(
                id: "log-2",
                name: "Feast",
                qty: 1,
                unit: "plate",
                calories: 3000,
                protein: 100,
                carbs: 200,
                fats: 80,
              ),
            ),
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    final text = tester.widget<Text>(
      find.byKey(const Key("calorie-ring-center")),
    );
    expect(text.data, "500");
    expect(text.style?.color, AppColors.mute);
    expect(find.text("over"), findsOneWidget);
    expect(text.style?.color, isNot(const Color(0xFFFFFFFF)));
    expect(text.style?.color, isNot(AppColors.statusGreen));
  });

  testWidgets("the ring jumps when animations are turned off", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const Scaffold(body: NutritionTab()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(center(tester), 2500);

    final today = foodLogDate(DateTime.now());
    container
        .read(clientRecordProvider.notifier)
        .update(
          (r) => r.copyWith(
            foodLog: r.foodLog.add(
              today,
              "breakfast",
              const FoodLogItem(
                id: "log-3",
                name: "Oats",
                qty: 1,
                unit: "bowl",
                calories: 500,
                protein: 20,
                carbs: 60,
                fats: 10,
              ),
            ),
          ),
        );
    await tester.pump();
    expect(center(tester), 2000);
    await tester.pump(const Duration(milliseconds: 400));
    expect(center(tester), 2000);
  });
}
