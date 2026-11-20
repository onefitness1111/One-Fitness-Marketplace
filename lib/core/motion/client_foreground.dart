import "package:flutter/foundation.dart";

/// Blocks the next client prompt while an earlier one is on screen.
///
/// Workout complete sets this while it is showing. The rating card waits
/// until it drops back to zero. On a build that does not show workout
/// complete, this stays at zero.
class ClientForeground {
  ClientForeground._();

  static final blockers = ValueNotifier<int>(0);

  static void pushBlock() => blockers.value++;

  static void popBlock() {
    if (blockers.value > 0) blockers.value--;
  }
}
