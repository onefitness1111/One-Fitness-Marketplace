import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:onefitness/core/nutrition/food_log_view.dart";
import "package:onefitness/core/nutrition/quick_add_macros.dart";
import "package:onefitness/data/models/food_log.dart";
import "package:onefitness/features/client/plans/food_log_section.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("each add-food tab explains itself once", (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: AddFoodSheet(
          mealLabel: "Breakfast",
          mealSlot: "breakfast",
          recents: const [],
          savedMeals: const [],
          onSnap: () async => null,
          onRestaurant: () async => null,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text("Add to Breakfast"), findsOneWidget);
    expect(find.text("Your meals"), findsWidgets);
    expect(find.textContaining("Foods you have logged"), findsOneWidget);
    expect(find.text("Snap"), findsNothing);

    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Search"));
    await tester.pumpAndSettle();
    expect(find.textContaining("Filter by a diet"), findsOneWidget);
    expect(find.text("Breakfast"), findsWidgets);
    expect(find.text("All"), findsOneWidget);

    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();
    expect(find.text("Take a pic"), findsOneWidget);
  });

  testWidgets("quick add keeps typed macros and estimates the blanks", (
    tester,
  ) async {
    final saved = await _openQuickAdd(
      tester,
      estimateMacros: (name, calories) async {
        throw Exception("the food list should answer this");
      },
    );

    expect(
      find.textContaining("leave protein, carbs, or fat blank"),
      findsOneWidget,
    );
    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), "Banana");
    await tester.enterText(find.byType(TextField).at(1), "210");
    await tester.tap(find.text("Log"));
    await tester.pumpAndSettle();

    expect(find.text("Log this estimate"), findsOneWidget);
    expect(find.textContaining("labels this Estimated"), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
      isNotEmpty,
    );
    await tester.tap(find.text("Log this estimate"));
    await tester.pumpAndSettle();

    final banana = saved.item!;
    expect(banana.name, "Banana");
    expect(banana.calories, 210);
    expect(banana.carbs, greaterThan(0));
    expect(foodLogEntryIsEstimated(banana), isTrue);
  });

  testWidgets("typing every macro logs it without an estimate", (tester) async {
    var calls = 0;
    final saved = await _openQuickAdd(
      tester,
      estimateMacros: (name, calories) async {
        calls += 1;
        return {"ok": true, "protein": 1, "carbs": 1, "fats": 1};
      },
    );
    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), "Trail mix");
    await tester.enterText(fields.at(1), "180");
    await tester.enterText(fields.at(2), "11");
    await tester.enterText(fields.at(3), "22");
    await tester.enterText(fields.at(4), "3");
    await tester.tap(find.text("Log"));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text("Log this estimate"), findsNothing);
    final item = saved.item!;
    expect(item.protein, 11);
    expect(item.carbs, 22);
    expect(item.fats, 3);
    expect(item.calories, 180);
    expect(foodLogEntryIsEstimated(item), isFalse);
  });

  testWidgets("a server estimate keeps the protein that was typed", (tester) async {
    final saved = await _openQuickAdd(tester, estimateMacros: (name, calories) async {
      return {"ok": true, "protein": 10, "carbs": 40, "fats": 10};
    });
    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), "Mystery stew");
    await tester.enterText(find.byType(TextField).at(1), "400");
    await tester.enterText(find.byType(TextField).at(2), "25");
    await tester.tap(find.text("Log"));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text, "25");
    expect(tester.widget<TextField>(find.byType(TextField).at(3)).controller!.text, isNotEmpty);
    expect(tester.widget<TextField>(find.byType(TextField).at(4)).controller!.text, isNotEmpty);
    await tester.enterText(find.byType(TextField).at(3), "30");
    await tester.tap(find.text("Log this estimate"));
    await tester.pumpAndSettle();

    final item = saved.item!;
    expect(item.protein, 25);
    expect(item.carbs, 30);
    expect(item.fats, greaterThan(0));
    expect(item.calories, 400);
    expect(foodLogEntryIsEstimated(item), isTrue);
  });

  testWidgets("a failed estimate can be logged as entered or retried", (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    final saved = await _openQuickAdd(
      tester,
      estimateMacros: (name, calories) => gate.future,
    );
    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), "Mystery stew");
    await tester.enterText(find.byType(TextField).at(1), "400");
    await tester.enterText(find.byType(TextField).at(2), "25");
    await tester.tap(find.text("Log"));
    await tester.pump();

    expect(find.text("Estimating the missing numbers."), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
      "25",
    );

    gate.complete({"ok": false, "error": "offline"});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(quickAddEstimateFailedMessage), findsOneWidget);
    expect(find.text("Log what I entered"), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
      "25",
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(3)).controller!.text,
      isEmpty,
    );

    await tester.tap(find.text("Log what I entered"));
    await tester.pumpAndSettle();

    final item = saved.item!;
    expect(item.name, "Mystery stew");
    expect(item.calories, 400);
    expect(item.protein, 25);
    expect(item.carbs, 0);
    expect(item.fats, 0);
    expect(foodLogEntryIsEstimated(item), isFalse);
  });
}

class _SavedFood {
  FoodLogItem? item;
}

Future<_SavedFood> _openQuickAdd(
  WidgetTester tester, {
  required Future<Map<String, dynamic>> Function(String name, int calories)
  estimateMacros,
}) async {
  SharedPreferences.setMockInitialValues({});
  final saved = _SavedFood();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  saved.item = await showModalBottomSheet<FoodLogItem>(
                    context: context,
                    isScrollControlled: true,
                    builder: (ctx) => AddFoodSheet(
                      mealLabel: "Lunch",
                      mealSlot: "lunch",
                      recents: const [],
                      savedMeals: const [],
                      onSnap: () async => null,
                      onRestaurant: () async => null,
                      estimateMacros: estimateMacros,
                    ),
                  );
                },
                child: const Text("Open"),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text("Open"));
  await tester.pumpAndSettle();
  await tester.tap(find.text("Dismiss"));
  await tester.pumpAndSettle();
  final quickAdd = find.widgetWithText(ChoiceChip, "Quick add");
  await tester.ensureVisible(quickAdd);
  await tester.pumpAndSettle();
  await tester.tap(quickAdd);
  await tester.pumpAndSettle();
  return saved;
}
