import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
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
}
