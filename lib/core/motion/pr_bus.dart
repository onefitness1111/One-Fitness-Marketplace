import "package:flutter/foundation.dart";

import "pr_logic.dart";

class PrFlash {
  const PrFlash({required this.exercise, required this.fromWeight, required this.toWeight, required this.setNum});

  final String exercise;
  final double fromWeight;
  final double toWeight;
  final int setNum;
}

/// Client-only. A celebration is shown once per entered weight and is not
/// stored, so a closed app does not replay it later.
class PrBus {
  PrBus._();

  static final instance = PrBus._();

  final flash = ValueNotifier<PrFlash?>(null);
  final _last = <String, double>{};

  static String key(String exercise, int setNum) => "${exercise.trim().toLowerCase()}|$setNum";

  void consider({
    required String exercise,
    required int setNum,
    required double? weight,
    required double? previousBest,
    required bool appInForeground,
  }) {
    final id = key(exercise, setNum);
    if (!weightIsPersonalRecord(previousBest: previousBest, weight: weight)) {
      _last.remove(id);
      return;
    }
    if (!shouldCelebratePr(
      previousBest: previousBest,
      weight: weight,
      lastCelebrated: _last[id],
      appInForeground: appInForeground,
    )) {
      return;
    }
    _last[id] = weight!;
    flash.value = PrFlash(exercise: exercise, fromWeight: previousBest!, toWeight: weight, setNum: setNum);
  }

  void dismiss() {
    if (flash.value != null) flash.value = null;
  }
}
