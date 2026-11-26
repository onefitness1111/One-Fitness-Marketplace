import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "../../../core/feature_flags.dart";
import "../../../core/theme/app_colors.dart";
import "../../../data/models/live_session.dart";
import "../../../data/providers/beep_providers.dart";
import "../../../data/providers/client_providers.dart";
import "beep_bar.dart";

/// Pinned-bar copy when Beep Your Coach has nothing to render, so the bar
/// is never an empty box.
const coachStartedWorkoutLabel = "Your coach started your workout";

/// True when [BeepBar] will show the button (a trainer id is available).
bool coachLiveBarShowsBeep(CoachLedDay day, LiveSession? beepable) {
  if (beepable != null && beepable.trainerId.isNotEmpty) return true;
  final trainerId = day.trainerId;
  return trainerId != null && trainerId.isNotEmpty;
}

/// What a client sees on every screen while their coach has a session running:
///
///  * the moment the coach starts it (or when the client opens the app
///    mid-session), the app goes straight to Plans > Workout and opens the
///    coach-led day in follow-along mode (L2) — no pop-up first, and
///  * a pinned bar with the Beep Your Coach button (only while
///    kBeepYourCoachEnabled) and a way to message the coach, on every other
///    screen for as long as the session is live. On Plans the workout page
///    carries its own small "Message your coach" banner.
///
/// Both are driven by [liveSessionsProvider], which the realtime channel on
/// `session_runs` keeps current. RLS only returns sessions the client is
/// booked into, so nothing here needs to re-check eligibility.
class ClientLiveSessionLayer extends ConsumerStatefulWidget {
  const ClientLiveSessionLayer({
    super.key,
    required this.screen,
    required this.onOpenChat,
    this.onOpenWorkout,
  });

  /// The client shell's current screen, so the pinned bar can step aside
  /// where it would double up (the workout tab already carries a beep bar)
  /// or collide with another pinned button.
  final String screen;
  final VoidCallback onOpenChat;
  final VoidCallback? onOpenWorkout;

  @override
  ConsumerState<ClientLiveSessionLayer> createState() => _ClientLiveSessionLayerState();
}

class _ClientLiveSessionLayerState extends ConsumerState<ClientLiveSessionLayer> {
  /// Coach-led days already opened, so the logging page opens once per
  /// session and a client who steps away isn't pulled back on every rebuild.
  final Set<String> _announced = {};

  @override
  void initState() {
    super.initState();
    // Opening the app mid-session goes straight to the workout too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final clientId = ref.read(clientInfoProvider).id;
      _openIfNew(ref.read(coachLedDaysProvider.notifier).forClient(clientId));
    });
  }

  /// L2: when the coach starts the session the client lands on Plans >
  /// Workout with the coach-led day open in follow-along mode (WorkoutTab
  /// opens the day itself). No pop-up in between; a small banner keeps
  /// "Message your coach" one tap away.
  void _openIfNew(CoachLedDay? led) {
    if (led == null || _announced.contains(led.dayId)) return;
    _announced.add(led.dayId);
    widget.onOpenWorkout?.call();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<CoachLedDay>>(coachLedDaysProvider, (prev, next) {
      final clientId = ref.read(clientInfoProvider).id;
      CoachLedDay? led;
      for (final day in next) {
        if (day.clientId == clientId) {
          led = day;
          break;
        }
      }
      _openIfNew(led);
    });

    final clientId = ref.watch(clientInfoProvider).id;
    final coachLed = ref.watch(coachLedDaysProvider.notifier).forClient(clientId);
    ref.watch(coachLedDaysProvider);
    // The workout tab renders its own BeepBar next to the exercise being done.
    // A booked session with no coach-started program day does not show it.
    if (coachLed == null || widget.screen == "plans") return const SizedBox.shrink();

    final beepable = ref.watch(liveSessionsProvider.notifier).beepable;
    ref.watch(liveSessionsProvider);
    final showBeep = kBeepYourCoachEnabled && coachLiveBarShowsBeep(coachLed, beepable);

    return Positioned(
      left: 12,
      right: 12,
      // The Booking tab pins its own button at the bottom.
      bottom: widget.screen == "booking" ? 62 : 8,
      child: Material(
        color: AppColors.card,
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: showBeep
                    ? const BeepBar(exerciseNames: [], focusIndex: 0)
                    : Text(
                        coachStartedWorkoutLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.txt,
                        ),
                      ),
              ),
              IconButton(
                tooltip: "Message your coach",
                onPressed: widget.onOpenChat,
                icon: Icon(LucideIcons.messageSquare, color: AppColors.gold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
