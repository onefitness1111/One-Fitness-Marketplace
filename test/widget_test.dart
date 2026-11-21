import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:onefitness/data/providers/supabase_bootstrap_provider.dart";
import "package:onefitness/main.dart";

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets("Client sign-in screen renders by default", (WidgetTester tester) async {
    // The real bootstrap opens Supabase, which starts refresh timers. This
    // test only checks the signed-out screen, so the load is skipped.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        supabaseBootstrapProvider.overrideWith((ref) async {}),
      ],
      child: const OneFitnessApp(),
    ));
    await tester.pumpAndSettle();

    expect(find.text("Welcome to ONE FITNESS"), findsOneWidget);
    expect(find.text("Sign in"), findsOneWidget);
    expect(find.text("Coach"), findsOneWidget);
    expect(find.text("Client"), findsOneWidget);
  });
}
