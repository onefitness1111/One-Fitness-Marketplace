import "dart:async";

import "package:flutter/foundation.dart";

/// Notification permission, then the waiver, on the first tap after login.
///
/// A scroll never calls [claim]. Buttons do. The first one wins and the
/// tap's own action waits until the next tap.
class LoginPrompts {
  static bool armed = false;
  static bool holding = false;
  static bool _once = false;
  static Future<void> Function()? _handler;
  static Future<void> _ready = Future<void>.value();

  /// Completes when the dashboard's first data wave has been painted, or
  /// immediately when that wave is not running (a cached paint, tests).
  static Future<void> whenDashboardReady() => _ready;

  static void beginDashboardLoad() {
    finishDashboardLoad();
    final done = Completer<void>();
    _ready = done.future;
    _pendingReady = done;
  }

  static Completer<void>? _pendingReady;

  static void finishDashboardLoad() {
    final pending = _pendingReady;
    _pendingReady = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// Arms the first-tap sequence once per sign-in. A later refresh must
  /// not ask again.
  static void arm() {
    if (_once) return;
    _once = true;
    armed = true;
  }

  /// The shell registers what "notification, then waiver" means for this
  /// screen. Replaced on rebuild so the closure stays current.
  static void attach(Future<void> Function() handler) {
    if (armed) _handler = handler;
  }

  /// True when this tap should be swallowed because the prompts ran.
  static bool claim() {
    if (!armed) return false;
    armed = false;
    holding = true;
    final run = _handler;
    _handler = null;
    if (run != null) {
      unawaited(run().whenComplete(() => holding = false));
    } else {
      holding = false;
    }
    return true;
  }

  static void reset() {
    armed = false;
    holding = false;
    _once = false;
    _handler = null;
    finishDashboardLoad();
    _ready = Future<void>.value();
  }
}

/// Wraps a button callback so the first tap after login shows the prompts
/// and does not run [action]. A null callback stays null (disabled).
VoidCallback? gateLoginTap(VoidCallback? action) {
  if (action == null) return null;
  return () {
    if (LoginPrompts.claim()) return;
    action();
  };
}

/// Notification permission first, then the waiver when one is still due.
///
/// The waiver future is not started until the notification future has
/// finished, which is the order the first tap has to keep.
Future<void> runLoginPromptSequence({
  required Future<void> Function() requestNotifications,
  required bool Function() waiverNeeded,
  required Future<void> Function() showWaiver,
}) async {
  await requestNotifications();
  if (waiverNeeded()) await showWaiver();
}
