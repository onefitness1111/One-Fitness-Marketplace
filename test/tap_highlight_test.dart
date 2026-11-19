import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/theme/app_colors.dart";
import "package:onefitness/core/theme/app_theme.dart";
import "package:onefitness/core/widgets/tap_highlight.dart";

void main() {
  tearDown(() => AppColors.apply(AppPalette.dark));

  testWidgets("a press shows the wash, and a chosen row keeps it", (tester) async {
    AppColors.apply(AppPalette.dark);
    var chosen = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.current,
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(
              child: TapHighlight(
                selected: chosen,
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => chosen = !chosen),
                child: const Text("Leg press"),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(TapWash), findsNothing);

    final gesture = await tester.startGesture(tester.getCenter(find.text("Leg press")));
    await tester.pump();
    final pressed = tester.widget<TapWash>(find.byType(TapWash));
    expect(pressed.color, AppColors.pressOverlay);
    expect(pressed.color.a, greaterThan(0.12));
    expect(pressed.color.a, lessThan(0.21));

    await gesture.up();
    await tester.pump();
    final held = tester.widget<TapWash>(find.byType(TapWash));
    expect(held.color, AppColors.selectedOverlay);

    await tester.tap(find.text("Leg press"));
    await tester.pump();
    expect(find.byType(TapWash), findsNothing);
  });

  test("buttons and menus take the wash from the theme", () {
    AppColors.apply(AppPalette.dark);
    final theme = AppTheme.current;
    expect(theme.splashFactory, isNot(NoSplash.splashFactory));
    expect(theme.highlightColor, AppColors.pressOverlay);
    expect(theme.focusColor, AppColors.selectedOverlay);
    expect(theme.elevatedButtonTheme.style?.overlayColor?.resolve({WidgetState.pressed}), AppColors.pressOverlay);
    expect(theme.chipTheme.selectedColor, AppColors.gold);
  });
}
