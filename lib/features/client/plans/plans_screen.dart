import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/beep_providers.dart";
import "../../../data/providers/client_providers.dart";
import "nutrition_tab.dart";
import "workout_tab.dart";

/// Mirrors ClientPlans (ClientNutritionEditor.jsx) — a two-tab view: Workout
/// Program and Nutrition Program. Swipeable via SwipeableTabView — see
/// client_shell.dart's `_swipeOwnedByScreen` for why the shell's own
/// swipe-to-go-back gesture steps aside on this screen.
///
/// L2: when the coach starts a session while the client is already here on
/// Nutrition, the page moves to Workout, where the coach-led day opens.
class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key});

  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen> {
  int _focusRequest = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<List<CoachLedDay>>(coachLedDaysProvider, (prev, next) {
      final clientId = ref.read(clientInfoProvider).id;
      bool has(List<CoachLedDay>? days) => (days ?? const []).any((d) => d.clientId == clientId);
      String? dayOf(List<CoachLedDay>? days) {
        for (final d in days ?? const <CoachLedDay>[]) {
          if (d.clientId == clientId) return d.dayId;
        }
        return null;
      }
      if (has(next) && dayOf(next) != dayOf(prev)) setState(() => _focusRequest++);
    });
    return SwipeableTabView(
      labels: const ["Workout Program", "Nutrition Program"],
      focusIndex: 0,
      focusRequest: _focusRequest,
      children: const [WorkoutTab(), NutritionTab()],
    );
  }
}
