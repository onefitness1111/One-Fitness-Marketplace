import "../../data/models/booking.dart";
import "../../data/models/measurement.dart";
import "../../data/models/progress_photo.dart";
import "../../data/models/workout_log.dart";
import "notification_triggers.dart";

/// Numbers for the monthly report, the goal bar, and the share card.
/// Photos themselves stay in private storage. The report attaches the
/// short-lived signed links the photo gallery already uses.

class MeasurementChange {
  const MeasurementChange({required this.label, required this.before, required this.after});

  final String label;
  final double before;
  final double after;

  double get delta => after - before;
}

class LiftGain {
  const LiftGain({required this.name, required this.before, required this.after});

  final String name;
  final double before;
  final double after;

  double get delta => after - before;
}

class ProgressSummary {
  const ProgressSummary({
    required this.sessionsDone,
    required this.workoutsLogged,
    required this.liftGains,
    required this.changes,
    required this.photoCount,
  });

  final int sessionsDone;
  final int workoutsLogged;
  final List<LiftGain> liftGains;
  final List<MeasurementChange> changes;
  final int photoCount;

  MeasurementChange? changeFor(String label) {
    for (final c in changes) {
      if (c.label == label) return c;
    }
    return null;
  }
}

bool _inRange(String date, String? from, String? to) {
  if (from != null && date.compareTo(from) < 0) return false;
  if (to != null && date.compareTo(to) > 0) return false;
  return true;
}

/// Checked-in sessions whose date falls in [from, to]. Both bounds are
/// inclusive ISO dates. Null means no bound.
int sessionsDoneIn({
  required String clientId,
  required List<Booking> bookings,
  String? from,
  String? to,
}) =>
    bookings
        .where((b) =>
            b.clientId == clientId &&
            b.attendanceStatus == "checked-in" &&
            b.status != "cancelled" &&
            _inRange(b.date, from, to))
        .length;

/// Heaviest completed set the first time an exercise was logged in the
/// window, against the heaviest set the last time. Only increases are
/// returned, largest first.
List<LiftGain> strengthGains(List<WorkoutLogEntry> logs, {String? from, String? to}) {
  final ordered = [...logs.where((l) => _inRange(l.date, from, to))]
    ..sort((a, b) => a.date.compareTo(b.date));
  final first = <String, double>{};
  final last = <String, double>{};
  for (final log in ordered) {
    for (final ex in log.exercises) {
      final weights = ex.sets
          .where((s) => (s.completed || (s.completedWeight ?? 0) > 0) && (s.completedWeight ?? 0) > 0)
          .map((s) => s.completedWeight!);
      if (weights.isEmpty) continue;
      final maxW = weights.reduce((a, b) => a > b ? a : b);
      first.putIfAbsent(ex.name, () => maxW);
      last[ex.name] = maxW;
    }
  }
  final gains = <LiftGain>[];
  for (final name in first.keys) {
    final before = first[name]!;
    final after = last[name]!;
    if (after > before) gains.add(LiftGain(name: name, before: before, after: after));
  }
  gains.sort((a, b) => b.delta.compareTo(a.delta));
  return gains;
}

const _inchFields = ["chest", "waist", "hips", "arms", "thighs"];

/// Weight and inch changes across the window. The "before" number is the
/// earliest entry in the window, or the last entry before it when the
/// window itself has only the new number.
List<MeasurementChange> bodyChanges(List<Measurement> measurements, {String? from, String? to}) {
  final ordered = [...measurements]..sort((a, b) => a.date.compareTo(b.date));
  final inWindow = ordered.where((m) => _inRange(m.date, from, to)).toList();
  if (inWindow.isEmpty) return const [];
  final beforeWindow = ordered.where((m) => from != null && m.date.compareTo(from) < 0).toList();

  double? read(Measurement m, String key) => parseLeadingNum(switch (key) {
        "weight" => m.weight,
        "chest" => m.chest,
        "waist" => m.waist,
        "hips" => m.hips,
        "arms" => m.arms,
        "thighs" => m.thighs,
        _ => null,
      });

  String label(String key) => switch (key) {
        "weight" => "Weight",
        "chest" => "Chest",
        "waist" => "Waist",
        "hips" => "Hips",
        "arms" => "Arms",
        "thighs" => "Thighs",
        _ => key,
      };

  double? latestOf(String key) {
    for (final m in inWindow.reversed) {
      final v = read(m, key);
      if (v != null) return v;
    }
    return null;
  }

  double? earliestOf(String key) {
    for (final m in inWindow) {
      final v = read(m, key);
      if (v != null) return v;
    }
    return null;
  }

  final out = <MeasurementChange>[];
  for (final key in ["weight", ..._inchFields]) {
    final newest = latestOf(key);
    if (newest == null) continue;
    var oldest = earliestOf(key);
    if (oldest == null || oldest == newest) {
      for (final m in beforeWindow.reversed) {
        final prior = read(m, key);
        if (prior != null) {
          oldest = prior;
          break;
        }
      }
    }
    if (oldest == null || oldest == newest) continue;
    out.add(MeasurementChange(label: label(key), before: oldest, after: newest));
  }
  return out;
}

/// How far [current] has moved from [start] toward [target], from 0 to 1.
/// Works for a weight they want to lose and a lift they want to add,
/// because the direction is start toward target.
double goalFraction({required double start, required double current, required double target}) {
  final span = target - start;
  if (span == 0) return current == target ? 1 : 0;
  final raw = (current - start) / span;
  if (raw.isNaN || raw.isInfinite) return 0;
  return raw.clamp(0.0, 1.0);
}

ProgressSummary summarizeProgress({
  required String clientId,
  required List<Booking> bookings,
  required List<WorkoutLogEntry> logs,
  required List<Measurement> measurements,
  required List<ProgressPhoto> photos,
  String? from,
  String? to,
}) =>
    ProgressSummary(
      sessionsDone: sessionsDoneIn(clientId: clientId, bookings: bookings, from: from, to: to),
      workoutsLogged: logs.where((l) => _inRange(l.date, from, to)).length,
      liftGains: strengthGains(logs, from: from, to: to),
      changes: bodyChanges(measurements, from: from, to: to),
      photoCount: photos.where((p) => _inRange(p.date, from, to)).length,
    );

double? _measureField(Measurement m, String field) => parseLeadingNum(switch (field) {
      "weight" => m.weight,
      "chest" => m.chest,
      "waist" => m.waist,
      "hips" => m.hips,
      "arms" => m.arms,
      "thighs" => m.thighs,
      _ => null,
    });

/// Latest then earliest reading of a body field. Null when nothing is logged.
(double?, double?) measurementEnds(List<Measurement> measurements, String field) {
  final ordered = [...measurements]..sort((a, b) => a.date.compareTo(b.date));
  double? first;
  double? last;
  for (final m in ordered) {
    final v = _measureField(m, field);
    if (v == null) continue;
    first ??= v;
    last = v;
  }
  return (first, last);
}

/// Heaviest completed weight the first time [name] was logged, and the
/// heaviest the last time.
(double?, double?) liftEnds(List<WorkoutLogEntry> logs, String name) {
  final ordered = [...logs]..sort((a, b) => a.date.compareTo(b.date));
  double? first;
  double? last;
  for (final log in ordered) {
    for (final ex in log.exercises) {
      if (ex.name != name) continue;
      final weights = ex.sets
          .where((s) => (s.completed || (s.completedWeight ?? 0) > 0) && (s.completedWeight ?? 0) > 0)
          .map((s) => s.completedWeight!);
      if (weights.isEmpty) continue;
      final maxW = weights.reduce((a, b) => a > b ? a : b);
      first ??= maxW;
      last = maxW;
    }
  }
  return (first, last);
}

/// Oldest and newest photos in the window, for the before/after slider
/// and the monthly email. Ordered oldest first.
List<ProgressPhoto> beforeAfterPhotos(List<ProgressPhoto> photos, {String? from, String? to}) {
  final inWindow = photos.where((p) => _inRange(p.date, from, to)).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  if (inWindow.length < 2) return inWindow;
  return [inWindow.first, inWindow.last];
}
