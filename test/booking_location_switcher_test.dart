import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/booking_places.dart";
import "package:onefitness/features/client/booking/booking_location_switcher.dart";

void main() {
  const burbank = BookablePlace(
    id: "addr:burbank",
    label: "Burbank Gym",
    address: "123 Main St, Burbank, CA 91502",
    aliases: {"Burbank Gym"},
  );

  testWidgets("the location chip opens the list and remembers the tap", (tester) async {
    String? chosen = "unset";
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BookingLocationSwitcher(
          places: const [burbank],
          selectedId: null,
          onSelect: (id) => chosen = id,
        ),
      ),
    ));

    expect(find.text("Location"), findsOneWidget);
    expect(find.text("All locations"), findsOneWidget);

    await tester.tap(find.text("Location"));
    await tester.pumpAndSettle();

    expect(find.text("Burbank Gym"), findsWidgets);
    expect(find.text("123 Main St, Burbank, CA 91502"), findsOneWidget);
    await tester.tap(find.text("Burbank Gym").last);
    await tester.pumpAndSettle();

    expect(chosen, "addr:burbank");
  });
}
