import "dart:io" show Platform;

import "package:flutter/foundation.dart" show kIsWeb;
import "package:health/health.dart";

/// Steps, heart rate, and weight read from Apple Health.
///
/// Nothing is written back. The system permission sheet is only shown
/// after the client has read a plain explanation in the app.
class AppleHealthReading {
  const AppleHealthReading({this.stepsToday, this.heartRate, this.weightLb});

  final int? stepsToday;
  final int? heartRate;
  final double? weightLb;

  bool get hasAny => stepsToday != null || heartRate != null || weightLb != null;
}

class AppleHealth {
  AppleHealth._();

  static final Health _health = Health();
  static const _types = [
    HealthDataType.STEPS,
    HealthDataType.HEART_RATE,
    HealthDataType.WEIGHT,
  ];
  static const _read = [
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
  ];

  static bool get supported => !kIsWeb && Platform.isIOS;

  static Future<bool> requestRead() async {
    if (!supported) return false;
    await _health.configure();
    return _health.requestAuthorization(_types, permissions: _read);
  }

  static Future<AppleHealthReading> read() async {
    if (!supported) return const AppleHealthReading();
    await _health.configure();
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final weekAgo = now.subtract(const Duration(days: 7));
    int? steps;
    try {
      steps = await _health.getTotalStepsInInterval(startOfDay, now);
    } catch (_) {
      steps = null;
    }
    List<HealthDataPoint> points = const [];
    try {
      points = await _health.getHealthDataFromTypes(
        types: const [HealthDataType.HEART_RATE, HealthDataType.WEIGHT],
        startTime: weekAgo,
        endTime: now,
        preferredUnits: const {HealthDataType.WEIGHT: HealthDataUnit.POUND},
      );
    } catch (_) {
      points = const [];
    }
    HealthDataPoint? newest(HealthDataType type) {
      HealthDataPoint? pick;
      for (final point in points) {
        if (point.type != type) continue;
        if (pick == null || point.dateTo.isAfter(pick.dateTo)) pick = point;
      }
      return pick;
    }

    final hr = newest(HealthDataType.HEART_RATE);
    final weight = newest(HealthDataType.WEIGHT);
    return AppleHealthReading(
      stepsToday: steps,
      heartRate: _round(hr),
      weightLb: _pounds(weight),
    );
  }

  static int? _round(HealthDataPoint? point) {
    final value = point?.value;
    if (value is! NumericHealthValue) return null;
    return value.numericValue.round();
  }

  /// The phone may hand back kilograms. The rest of the app speaks in pounds.
  static double? _pounds(HealthDataPoint? point) {
    final value = point?.value;
    if (value is! NumericHealthValue) return null;
    final n = value.numericValue.toDouble();
    return switch (point!.unit) {
      HealthDataUnit.KILOGRAM => n * 2.2046226218,
      HealthDataUnit.GRAM => n / 453.59237,
      HealthDataUnit.OUNCE => n / 16,
      HealthDataUnit.STONE => n * 14,
      _ => n,
    };
  }
}
