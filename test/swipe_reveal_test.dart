import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/widgets/swipe_reveal.dart";

void main() {
  testWidgets("swiping left reveals Exchange and tapping it runs the action", (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 320,
              height: 88,
              child: SwipeReveal(
                onExchange: () => taps++,
                child: const ColoredBox(color: Color(0xFFFFFFFF), child: SizedBox.expand(child: Text("Bench Press"))),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text("Bench Press"), const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(find.text("Exchange"), findsOneWidget);
    await tester.tap(find.text("Exchange"));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets("a disabled row does not offer Exchange", (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SwipeReveal(enabled: false, onExchange: _noop, child: Text("Row")),
      ),
    );
    expect(find.text("Exchange"), findsNothing);
    expect(find.text("Row"), findsOneWidget);
  });
}

void _noop() {}
