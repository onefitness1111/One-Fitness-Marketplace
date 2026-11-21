import "dart:io" show Platform;

import "package:flutter/foundation.dart" show kIsWeb;
import "package:health/health.dart";

import "health_stats.dart";

/// What happened when the client asked to connect.
class WearableAttempt {
  const WearableAttempt({required this.granted, this.needsInstall = false, this.reading});

  final bool granted;
  final bool needsInstall;
  final HealthReading? reading;
}

/// Read-only access to Apple Health on iOS and Health Connect on Android.
///
/// The system permission sheet is not opened from here until the caller has
/// already shown the in-app explanation. Nothing is written back.
class WearableReader {
  WearableReader({Health? health}) : _health = health;

  final Health? _health;

  Health get _plugin => _health ?? Health();

  static bool get supported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static HealthPlatform get platform {
    if (kIsWeb) return HealthPlatform.other;
    if (Platform.isIOS) return HealthPlatform.ios;
    if (Platform.isAndroid) return HealthPlatform.android;
    return HealthPlatform.other;
  }

  static List<HealthDataType> typesFor({required bool ios}) {
    const shared = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.HEART_RATE,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.WORKOUT,
      HealthDataType.WEIGHT,
      HealthDataType.BODY_FAT_PERCENTAGE,
      HealthDataType.LEAN_BODY_MASS,
    ];
    if (ios) return [...shared, HealthDataType.HEART_RATE_VARIABILITY_SDNN];
    return [...shared, HealthDataType.SLEEP_SESSION, HealthDataType.HEART_RATE_VARIABILITY_RMSSD];
  }

  List<HealthDataAccess> _reads(int count) => List<HealthDataAccess>.filled(count, HealthDataAccess.READ);

  Future<bool?> hasReadAccess() async {
    if (!supported) return false;
    final health = _plugin;
    await health.configure();
    if (Platform.isAndroid && !await health.isHealthConnectAvailable()) return false;
    final types = typesFor(ios: Platform.isIOS);
    return health.hasPermissions(types, permissions: _reads(types.length));
  }

  /// Explanation has already been shown. This is the system prompt, then a read.
  Future<WearableAttempt> connectAndRead() async {
    if (!supported) return const WearableAttempt(granted: false);
    final health = _plugin;
    await health.configure();
    if (Platform.isAndroid && !await health.isHealthConnectAvailable()) {
      await health.installHealthConnect();
      return const WearableAttempt(granted: false, needsInstall: true);
    }
    final types = typesFor(ios: Platform.isIOS);
    bool ok = false;
    try {
      ok = await health.requestAuthorization(types, permissions: _reads(types.length));
    } catch (_) {
      ok = false;
    }
    if (!ok) return const WearableAttempt(granted: false);
    if (Platform.isAndroid) {
      try {
        await health.requestHealthDataHistoryAuthorization();
      } catch (_) {}
    }
    final reading = await read();
    return WearableAttempt(granted: true, reading: reading);
  }

  Future<HealthReading> read() async {
    final now = DateTime.now();
    final ios = !kIsWeb && Platform.isIOS;
    if (!supported) {
      return HealthReading(
        days: const [],
        workouts: const [],
        syncedAt: now,
        sourceId: "none",
        sourceLabel: ios ? "Apple Health" : "Health Connect",
      );
    }
    final health = _plugin;
    await health.configure();
    final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 90));
    int? stepsToday;
    try {
      stepsToday = await health.getTotalStepsInInterval(DateTime(now.year, now.month, now.day), now);
    } catch (_) {
      stepsToday = null;
    }
    final points = <HealthDataPoint>[];
    for (final type in typesFor(ios: ios)) {
      try {
        points.addAll(await health.getHealthDataFromTypes(
          types: [type],
          startTime: start,
          endTime: now,
          preferredUnits: const {
            HealthDataType.WEIGHT: HealthDataUnit.POUND,
            HealthDataType.LEAN_BODY_MASS: HealthDataUnit.POUND,
            HealthDataType.ACTIVE_ENERGY_BURNED: HealthDataUnit.KILOCALORIE,
          },
        ));
      } catch (_) {}
    }
    return readingFromPoints(points, stepsToday: stepsToday, now: now, ios: ios);
  }
}

HealthReading readingFromPoints(
  List<HealthDataPoint> points, {
  required DateTime now,
  int? stepsToday,
  required bool ios,
}) {
  final samples = <NormalizedSample>[];
  final workouts = <HealthWorkout>[];
  final names = <String>{};
  for (final point in points) {
    final name = point.sourceName.trim();
    if (name.isNotEmpty) names.add(name);
    if (point.type == HealthDataType.WORKOUT) {
      final workout = _workout(point);
      if (workout != null) workouts.add(workout);
      continue;
    }
    final sample = _sample(point);
    if (sample != null) samples.add(sample);
  }
  return aggregateHealth(
    samples: samples,
    workouts: workouts,
    now: now,
    sourceId: ios ? "apple_health" : "health_connect",
    sourceLabel: ios ? "Apple Health" : "Health Connect",
    stepsToday: stepsToday,
    deviceNames: names,
  );
}

NormalizedSample? _sample(HealthDataPoint point) {
  final kind = switch (point.type) {
    HealthDataType.STEPS => SampleKind.steps,
    HealthDataType.ACTIVE_ENERGY_BURNED => SampleKind.activeEnergy,
    HealthDataType.RESTING_HEART_RATE => SampleKind.restingHr,
    HealthDataType.HEART_RATE => SampleKind.heartRate,
    HealthDataType.HEART_RATE_VARIABILITY_SDNN || HealthDataType.HEART_RATE_VARIABILITY_RMSSD => SampleKind.hrv,
    HealthDataType.WEIGHT => SampleKind.weight,
    HealthDataType.BODY_FAT_PERCENTAGE => SampleKind.bodyFat,
    HealthDataType.LEAN_BODY_MASS => SampleKind.leanMass,
    HealthDataType.SLEEP_DEEP || HealthDataType.SLEEP_REM || HealthDataType.SLEEP_LIGHT => SampleKind.sleepStage,
    HealthDataType.SLEEP_ASLEEP => SampleKind.sleepUnspecified,
    HealthDataType.SLEEP_SESSION => SampleKind.sleepSession,
    _ => null,
  };
  if (kind == null) return null;
  final value = _value(point, kind);
  if (value == null) return null;
  return NormalizedSample(kind: kind, from: point.dateFrom, to: point.dateTo, value: value);
}

double? _value(HealthDataPoint point, SampleKind kind) {
  final sleep = kind == SampleKind.sleepStage || kind == SampleKind.sleepUnspecified || kind == SampleKind.sleepSession;
  if (sleep) {
    final span = point.dateTo.difference(point.dateFrom).inMinutes;
    if (span > 0) return span.toDouble();
    final raw = point.value;
    if (raw is NumericHealthValue) return raw.numericValue.toDouble();
    return null;
  }
  final raw = point.value;
  if (raw is! NumericHealthValue) return null;
  final unit = point.unit.name;
  return switch (kind) {
    SampleKind.weight || SampleKind.leanMass => poundsFrom(raw.numericValue, unit),
    SampleKind.activeEnergy => kcalFrom(raw.numericValue, unit),
    SampleKind.bodyFat => bodyFatPercent(raw.numericValue),
    _ => raw.numericValue.toDouble(),
  };
}

HealthWorkout? _workout(HealthDataPoint point) {
  final value = point.value;
  if (value is! WorkoutHealthValue) return null;
  final burned = value.totalEnergyBurned;
  final unit = value.totalEnergyBurnedUnit?.name ?? "KILOCALORIE";
  final id = point.uuid.trim().isEmpty ? "${point.type.name}-${point.dateFrom.toIso8601String()}" : point.uuid.trim();
  return HealthWorkout(
    externalId: id,
    startedAt: point.dateFrom,
    endedAt: point.dateTo,
    activity: workoutActivityLabel(value.workoutActivityType.name),
    energyKcal: burned == null ? null : kcalFrom(burned, unit),
  );
}
