import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/data/models/food_log.dart";
import "package:onefitness/features/trainer/clients/client_food_log_view.dart";

void main() {
  testWidgets("the day picker shows the log and an empty next day", (tester) async {
    final log = FoodLog(days: {
      "2026-05-30": {
        "breakfast": [
          const FoodLogItem(id: "snap-1", name: "Chicken plate", qty: 1, unit: "plate", calories: 540, protein: 40, carbs: 30, fats: 22),
        ],
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FoodLogDayPage(log: log, initialDay: DateTime(2026, 5, 30))),
    ));

    expect(find.text("Chicken plate"), findsOneWidget);
    expect(find.text("Estimated"), findsOneWidget);
    expect(find.textContaining("540 kcal"), findsWidgets);
    expect(find.text("No food logged this day."), findsNothing);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();

    expect(find.text("No food logged this day."), findsOneWidget);
    expect(find.text("Chicken plate"), findsNothing);
  });
}
