import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/features/trainer/schedule/balance_booking_warning.dart";

void main() {
  Future<void> open(
    WidgetTester tester, {
    bool bookAnyway = true,
    String? note,
    Future<String?> Function()? onCharge,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (ctx) => StaffBalanceDialog(
                  warning: "This client has an outstanding balance of \$25.00.",
                  bookAnywayEnabled: bookAnyway,
                  blockedNote: note,
                  onCharge: onCharge ?? () async => null,
                ),
              ),
              child: const Text("open"),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
  }

  testWidgets("the three choices stack in order and the first two match", (tester) async {
    await open(tester);
    final charge = tester.getTopLeft(find.text("Charge balance & book"));
    final anyway = tester.getTopLeft(find.text("Book session anyway"));
    final cancel = tester.getTopLeft(find.text("Cancel"));
    expect(charge.dy, lessThan(anyway.dy));
    expect(anyway.dy, lessThan(cancel.dy));
    expect(find.textContaining("card on file"), findsOneWidget);

    final filled = tester.getSize(find.byType(ElevatedButton));
    final outlined = tester.getSize(find.byType(OutlinedButton));
    expect(filled.height, outlined.height);
    expect(filled.width, outlined.width);
    expect(filled.height, 48);

    final style = tester.widget<ElevatedButton>(find.byType(ElevatedButton)).style!;
    expect(style.backgroundColor?.resolve({}), Colors.white);
    expect(style.foregroundColor?.resolve({}), Colors.black);
  });

  testWidgets("cancel closes without booking", (tester) async {
    await open(tester);
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();
    expect(find.text("Outstanding balance"), findsNothing);
  });

  testWidgets("book anyway is off once the coach has used the grace booking", (tester) async {
    await open(
      tester,
      bookAnyway: false,
      note: "You already added them to one session while this is unpaid.",
    );
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
    expect(find.text("You already added them to one session while this is unpaid."), findsOneWidget);
    expect(find.text("Charge balance & book"), findsOneWidget);
    expect(find.text("Cancel"), findsOneWidget);
  });

  testWidgets("a failed charge stays on the dialog and books nothing", (tester) async {
    await open(tester, onCharge: () async => "No card on file. Nothing was booked.");
    await tester.tap(find.text("Charge balance & book"));
    await tester.pump();
    await tester.pump();
    expect(find.text("No card on file. Nothing was booked."), findsOneWidget);
    expect(find.text("Book session anyway"), findsOneWidget);
    expect(find.text("Outstanding balance"), findsOneWidget);
    expect(find.textContaining("4242"), findsNothing);
    expect(find.textContaining("billing"), findsNothing);
  });

  testWidgets("a successful charge closes so the session can be booked", (tester) async {
    await open(tester, onCharge: () async => null);
    await tester.tap(find.text("Charge balance & book"));
    await tester.pumpAndSettle();
    expect(find.text("Outstanding balance"), findsNothing);
  });
}
