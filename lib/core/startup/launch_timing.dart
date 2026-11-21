import "package:flutter/foundation.dart";

/// Debug clock for the wait a person actually feels.
///
/// One stopwatch, started at process start. Prints only in debug builds:
/// process start, first Flutter frame, session restored, dashboard usable.
class LaunchTiming {
  LaunchTiming._();

  static final Stopwatch _clock = Stopwatch();
  static bool _started = false;
  static bool _frame = false;
  static bool _session = false;
  static bool _dashboard = false;

  static void markProcessStart() {
    if (_started) return;
    _started = true;
    _clock.start();
    _log("process start");
  }

  static void markFirstFrame() {
    if (_frame) return;
    _frame = true;
    _log("first frame");
  }

  static void markSessionRestored() {
    if (_session) return;
    _session = true;
    _log("session restored");
  }

  static void markDashboardUsable(String how) {
    if (_dashboard) return;
    _dashboard = true;
    _log("dashboard usable ($how)");
  }

  /// A step along the way. Does not change the four milestones above.
  static void phase(String name) => _log(name);

  static void _log(String label) {
    if (!kDebugMode) return;
    final ms = _started ? _clock.elapsedMilliseconds : 0;
    debugPrint("[launch] $label at ${ms}ms");
  }
}
