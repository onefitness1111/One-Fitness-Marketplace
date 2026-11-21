import "health_stats.dart";

/// What happened when the client asked to connect.
class WearableAttempt {
  const WearableAttempt({required this.granted, this.needsInstall = false, this.reading});

  final bool granted;
  final bool needsInstall;
  final HealthReading? reading;
}

/// Apple Health and Health Connect are phone features. The website does not
/// read them. The phone build uses [wearable_reader_io.dart] instead.
class WearableReader {
  WearableReader();

  static bool get supported => false;

  static HealthPlatform get platform => HealthPlatform.other;

  Future<bool?> hasReadAccess() async => false;

  Future<WearableAttempt> connectAndRead() async => const WearableAttempt(granted: false);

  Future<HealthReading> read() async {
    return HealthReading(
      days: const [],
      workouts: const [],
      syncedAt: DateTime.now(),
      sourceId: "none",
      sourceLabel: "none",
    );
  }
}
