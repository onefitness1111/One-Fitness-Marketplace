import "package:supabase_flutter/supabase_flutter.dart" show PostgrestException;

/// Daily step target shown on the tiles. Not a medical goal.
const int kDailyStepGoal = 10000;

enum HealthPlatform { ios, android, other }

enum SampleKind {
  steps,
  activeEnergy,
  restingHr,
  heartRate,
  hrv,
  weight,
  bodyFat,
  leanMass,
  sleepStage,
  sleepUnspecified,
  sleepSession,
}

/// One sample already converted into the units the rest of the app uses:
/// counts, kcal, bpm, milliseconds, pounds, percent, or minutes.
class NormalizedSample {
  const NormalizedSample({
    required this.kind,
    required this.from,
    required this.to,
    required this.value,
  });

  final SampleKind kind;
  final DateTime from;
  final DateTime to;
  final double value;
}

class HealthDay {
  const HealthDay({
    required this.day,
    this.steps,
    this.activeKcal,
    this.restingHr,
    this.heartRate,
    this.sleepMinutes,
    this.hrvMs,
    this.weightLb,
    this.bodyFatPct,
    this.leanMassLb,
  });

  final DateTime day;
  final int? steps;
  final double? activeKcal;
  final int? restingHr;
  final int? heartRate;
  final int? sleepMinutes;
  final double? hrvMs;
  final double? weightLb;
  final double? bodyFatPct;
  final double? leanMassLb;

  bool get hasAny =>
      steps != null ||
      activeKcal != null ||
      restingHr != null ||
      heartRate != null ||
      sleepMinutes != null ||
      hrvMs != null ||
      weightLb != null ||
      bodyFatPct != null ||
      leanMassLb != null;

  Map<String, dynamic> toRow(String clientId) => {
        "client_id": clientId,
        "day": isoDay(day),
        "steps": steps,
        "active_energy_kcal": activeKcal,
        "resting_heart_rate": restingHr,
        "heart_rate": heartRate,
        "sleep_minutes": sleepMinutes,
        "hrv_ms": hrvMs,
        "weight_lb": weightLb,
        "body_fat_pct": bodyFatPct,
        "lean_mass_lb": leanMassLb,
        "updated_at": DateTime.now().toUtc().toIso8601String(),
      };

  static HealthDay? fromRow(Map<String, dynamic> row) {
    final parsed = DateTime.tryParse("${row["day"]}");
    if (parsed == null) return null;
    return HealthDay(
      day: dateOnly(parsed),
      steps: asInt(row["steps"]),
      activeKcal: asDouble(row["active_energy_kcal"]),
      restingHr: asInt(row["resting_heart_rate"]),
      heartRate: asInt(row["heart_rate"]),
      sleepMinutes: asInt(row["sleep_minutes"]),
      hrvMs: asDouble(row["hrv_ms"]),
      weightLb: asDouble(row["weight_lb"]),
      bodyFatPct: asDouble(row["body_fat_pct"]),
      leanMassLb: asDouble(row["lean_mass_lb"]),
    );
  }
}

class HealthWorkout {
  const HealthWorkout({
    required this.externalId,
    required this.startedAt,
    required this.endedAt,
    required this.activity,
    this.energyKcal,
  });

  final String externalId;
  final DateTime startedAt;
  final DateTime endedAt;
  final String activity;
  final double? energyKcal;

  int get durationMin {
    final minutes = endedAt.difference(startedAt).inMinutes;
    return minutes < 0 ? 0 : minutes;
  }

  Map<String, dynamic> toRow(String clientId, String source) => {
        "client_id": clientId,
        "external_id": externalId,
        "started_at": startedAt.toUtc().toIso8601String(),
        "ended_at": endedAt.toUtc().toIso8601String(),
        "duration_min": durationMin,
        "activity": activity,
        "source": source,
        if (energyKcal != null) "energy_kcal": energyKcal,
        "updated_at": DateTime.now().toUtc().toIso8601String(),
      };

  static HealthWorkout? fromRow(Map<String, dynamic> row) {
    final start = DateTime.tryParse("${row["started_at"]}");
    if (start == null) return null;
    final end = DateTime.tryParse("${row["ended_at"]}") ?? start;
    final id = "${row["external_id"]}".trim();
    if (id.isEmpty) return null;
    return HealthWorkout(
      externalId: id,
      startedAt: start.toLocal(),
      endedAt: end.toLocal(),
      activity: "${row["activity"]}".trim().isEmpty ? "Workout" : "${row["activity"]}".trim(),
      energyKcal: asDouble(row["energy_kcal"]),
    );
  }
}

class HealthReading {
  const HealthReading({
    required this.days,
    required this.workouts,
    required this.syncedAt,
    required this.sourceId,
    required this.sourceLabel,
    this.deviceNames = const {},
  });

  final List<HealthDay> days;
  final List<HealthWorkout> workouts;
  final DateTime syncedAt;
  final String sourceId;
  final String sourceLabel;
  final Set<String> deviceNames;

  bool get hasAny => days.any((d) => d.hasAny) || workouts.isNotEmpty;

  HealthDay? dayOn(DateTime day) {
    final want = dateOnly(day);
    for (final entry in days) {
      if (dateOnly(entry.day) == want) return entry;
    }
    return null;
  }
}

class HealthFlag {
  const HealthFlag({required this.title, required this.detail, this.onTarget = false});

  final String title;
  final String detail;

  /// Uses the same green as the existing "On target" label. Nothing else in
  /// this feature does.
  final bool onTarget;
}

class HealthTrendLine {
  const HealthTrendLine({required this.label, required this.value, this.delta});

  final String label;
  final String value;
  final String? delta;
}

class ConnectOption {
  const ConnectOption({
    required this.id,
    required this.title,
    required this.body,
    this.actionLabel,
    this.comingSoon = false,
  });

  final String id;
  final String title;
  final String body;
  final String? actionLabel;
  final bool comingSoon;

  bool get canConnect => actionLabel != null && !comingSoon;
}

class HealthPersistOutcome {
  const HealthPersistOutcome({
    required this.saved,
    required this.storageUnavailable,
    required this.shareApplied,
    this.localOnly = false,
  });

  final bool saved;
  final bool storageUnavailable;
  final bool shareApplied;

  /// No signed-in account, so nothing was sent. The on-screen numbers stay.
  final bool localOnly;
}

enum BodyStat { weight, bodyFat, lean }

DateTime dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

String isoDay(DateTime value) {
  final day = dateOnly(value);
  final month = day.month.toString().padLeft(2, "0");
  final date = day.day.toString().padLeft(2, "0");
  return "${day.year}-$month-$date";
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.round();
  return null;
}

double? asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

String formatCount(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(",");
    out.write(digits[i]);
  }
  return negative ? "-$out" : out.toString();
}

String formatNumber(double value, {int decimals = 1}) {
  final factor = decimals == 0 ? 1.0 : 10.0;
  final rounded = (value * factor).round() / factor;
  if (decimals == 0 || rounded == rounded.roundToDouble()) {
    return rounded.toStringAsFixed(0);
  }
  return rounded.toStringAsFixed(decimals);
}

String formatSleep(int minutes) {
  if (minutes < 0) minutes = 0;
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  if (hours <= 0) return "${mins}m";
  return "${hours}h ${mins}m";
}

String formatClock(DateTime time) {
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, "0");
  final suffix = time.hour >= 12 ? "PM" : "AM";
  return "$hour:$minute $suffix";
}

String formatShortDate(DateTime time) {
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return "${months[time.month - 1]} ${time.day}";
}

double? poundsFrom(num value, String unit) {
  final n = value.toDouble();
  switch (unit.toUpperCase()) {
    case "KILOGRAM":
    case "KILOGRAMS":
      return n * 2.2046226218;
    case "GRAM":
    case "GRAMS":
      return n / 453.59237;
    case "OUNCE":
    case "OUNCES":
      return n / 16;
    case "STONE":
      return n * 14;
    default:
      return n;
  }
}

double? kcalFrom(num value, String unit) {
  final n = value.toDouble();
  switch (unit.toUpperCase()) {
    case "KILOJOULE":
    case "KILOJOULES":
      return n / 4.184;
    case "JOULE":
    case "JOULES":
      return n / 4184;
    case "SMALL_CALORIE":
      return n / 1000;
    default:
      return n;
  }
}

/// Apple Health sometimes stores body fat as a fraction (0.18) and sometimes
/// as a percent (18). A value of 1 or less is the fraction.
double? bodyFatPercent(num value) {
  final n = value.toDouble();
  if (n > 0 && n <= 1) return n * 100;
  return n;
}

String workoutActivityLabel(String raw) {
  final key = raw.trim().toUpperCase().replaceAll(" ", "_");
  const known = {
    "TRADITIONAL_STRENGTH_TRAINING": "Strength",
    "FUNCTIONAL_STRENGTH_TRAINING": "Strength",
    "STRENGTH_TRAINING": "Strength",
    "WEIGHTLIFTING": "Strength",
    "RUNNING": "Run",
    "WALKING": "Walk",
    "BIKING": "Ride",
    "CYCLING": "Ride",
    "YOGA": "Yoga",
    "HIGH_INTENSITY_INTERVAL_TRAINING": "HIIT",
    "SWIMMING": "Swim",
    "HIKING": "Hike",
    "ROWING": "Row",
    "ELLIPTICAL": "Elliptical",
    "STAIR_CLIMBING": "Stairs",
  };
  final hit = known[key];
  if (hit != null) return hit;
  if (key.isEmpty || key == "OTHER" || key == "UNKNOWN") return "Workout";
  return key.split("_").where((part) => part.isNotEmpty).map((part) {
    final lower = part.toLowerCase();
    return "${lower[0].toUpperCase()}${lower.substring(1)}";
  }).join(" ");
}

String workoutWhen(DateTime started, DateTime now) {
  final day = dateOnly(started);
  final today = dateOnly(now);
  if (day == today) return "Today";
  if (day == today.subtract(const Duration(days: 1))) return "Yesterday";
  return formatShortDate(started);
}

String syncedLine(DateTime syncedAt, DateTime now, String sourceLabel, Set<String> deviceNames) {
  final clock = formatClock(syncedAt);
  final day = dateOnly(syncedAt);
  final today = dateOnly(now);
  final when = day == today
      ? "today at $clock"
      : day == today.subtract(const Duration(days: 1))
          ? "yesterday at $clock"
          : "${formatShortDate(syncedAt)} at $clock";
  final extras = <String>[];
  for (final name in deviceNames) {
    final lower = name.toLowerCase();
    if (lower.contains("watch") && !extras.contains("Apple Watch")) extras.add("Apple Watch");
    if (lower.contains("oura") && !extras.contains("Oura")) extras.add("Oura");
  }
  return "Last synced $when · ${[sourceLabel, ...extras].join(", ")}";
}

/// The only name that belongs in the share sentence. Callers pass the coach
/// name clients already see, never a legal name.
String shareHealthCaption(String coachName) {
  final name = coachName.trim().isEmpty ? "your coach" : coachName.trim();
  return "Off until you turn it on. Only $name would see these stats. "
      "Your phone number, billing address, and legal name stay private.";
}

List<ConnectOption> connectOptions(HealthPlatform platform) {
  switch (platform) {
    case HealthPlatform.ios:
      return const [
        ConnectOption(
          id: "apple_health",
          title: "Apple Health",
          body: "On iPhone, this is the connection. It reads steps, active energy, heart rate, "
              "resting heart rate, heart rate variability, sleep, workouts, weight, body fat, and lean mass "
              "from the Health app after you agree. Read only. Nothing is written back. "
              "Apple Watch and Oura show up here once they save into Apple Health.",
          actionLabel: "Continue with Apple Health",
        ),
        ConnectOption(
          id: "apple_watch",
          title: "Apple Watch",
          body: "Watch data comes in through Apple Health. Connect Health, then wear your watch. "
              "There is no separate Watch login.",
        ),
        ConnectOption(
          id: "oura",
          title: "Oura Ring",
          body: "Oura also comes in through Apple Health. Connect Health, not a separate Oura login in this app.",
        ),
        ConnectOption(
          id: "fitbit",
          title: "Fitbit",
          body: "On iPhone, Fitbit does not come through Apple Health. A direct Fitbit sign-in needs a "
              "Fitbit developer account this app does not have yet.",
          comingSoon: true,
        ),
      ];
    case HealthPlatform.android:
      return const [
        ConnectOption(
          id: "health_connect",
          title: "Health Connect",
          body: "On Android, this is the connection. It reads steps, active energy, heart rate, "
              "resting heart rate, heart rate variability, sleep, workouts, weight, body fat, and lean mass "
              "from apps that sync to Health Connect, after you agree. Read only. Nothing is written back. "
              "Android may also ask to read older history so the 90-day charts have something to show.",
          actionLabel: "Continue with Health Connect",
        ),
        ConnectOption(
          id: "fitbit",
          title: "Fitbit",
          body: "Included with Health Connect when Fitbit is already linked there. No separate Fitbit sign-in in this app.",
        ),
        ConnectOption(
          id: "oura",
          title: "Oura Ring",
          body: "Included with Health Connect when Oura syncs there. No separate Oura login in this app.",
        ),
        ConnectOption(
          id: "samsung",
          title: "Samsung Health",
          body: "Included with Health Connect when Samsung Health syncs there, along with other apps that do the same.",
        ),
      ];
    case HealthPlatform.other:
      return const [];
  }
}

/// True when Postgres or PostgREST says the health tables are not there yet.
/// Build 17 ships before that migration is applied, so this has to be a
/// normal state, not a crash.
bool healthStorageUnavailable(Object error) {
  if (error is PostgrestException) {
    final code = error.code ?? "";
    if (code == "42P01" || code == "PGRST205" || code == "PGRST204" || code == "PGRST202") {
      return true;
    }
    final message = error.message.toLowerCase();
    final namesHealth = message.contains("health_connections") ||
        message.contains("health_daily_stats") ||
        message.contains("health_workouts");
    if (namesHealth &&
        (message.contains("does not exist") || message.contains("schema cache") || message.contains("could not find"))) {
      return true;
    }
  }
  final text = error.toString().toLowerCase();
  final namesHealth = text.contains("health_connections") || text.contains("health_daily_stats") || text.contains("health_workouts");
  return namesHealth && (text.contains("does not exist") || text.contains("schema cache") || text.contains("could not find"));
}

HealthPersistOutcome persistOutcome({Object? error, required bool requestedShare, bool localOnly = false}) {
  if (localOnly) {
    return const HealthPersistOutcome(saved: false, storageUnavailable: false, shareApplied: false, localOnly: true);
  }
  if (error == null) {
    return HealthPersistOutcome(saved: true, storageUnavailable: false, shareApplied: requestedShare);
  }
  return HealthPersistOutcome(
    saved: false,
    storageUnavailable: healthStorageUnavailable(error),
    shareApplied: false,
  );
}

String healthSaveNote({
  required HealthPersistOutcome outcome,
  required String coachName,
}) {
  final name = coachName.trim().isEmpty ? "your coach" : coachName.trim();
  if (outcome.localOnly) {
    return "These stay on this phone.";
  }
  if (outcome.storageUnavailable) {
    return "These stay on this phone. Sharing with your coach isn't available until health storage is turned on.";
  }
  if (!outcome.saved) {
    return "Couldn't save just now. These stay on this phone, and your coach can't see them.";
  }
  if (outcome.shareApplied) return "Shared with $name.";
  return "Saved to your account. Your coach can't see this until you turn sharing on.";
}

/// The coach section is hidden unless the client has turned sharing on and
/// the tables answered. A missing table and a refused read both hide it.
bool coachShouldShowHealth({
  required bool shareWithCoach,
  required bool storageUnavailable,
  required bool hasAnyStat,
}) {
  if (storageUnavailable || !shareWithCoach || !hasAnyStat) return false;
  return true;
}

HealthReading aggregateHealth({
  required List<NormalizedSample> samples,
  required List<HealthWorkout> workouts,
  required DateTime now,
  required String sourceId,
  required String sourceLabel,
  int? stepsToday,
  Set<String> deviceNames = const {},
}) {
  final buckets = <DateTime, _DayBucket>{};
  _DayBucket bucketFor(DateTime day) => buckets.putIfAbsent(dateOnly(day), () => _DayBucket(dateOnly(day)));

  for (final sample in samples) {
    final bucket = bucketFor(_bucketDay(sample));
    switch (sample.kind) {
      case SampleKind.steps:
        bucket.steps = (bucket.steps ?? 0) + sample.value.round();
      case SampleKind.activeEnergy:
        bucket.active = (bucket.active ?? 0) + sample.value;
      case SampleKind.restingHr:
        if (bucket.restingAt == null || sample.to.isAfter(bucket.restingAt!)) {
          bucket.restingAt = sample.to;
          bucket.resting = sample.value.round();
        }
      case SampleKind.heartRate:
        if (bucket.hrAt == null || sample.to.isAfter(bucket.hrAt!)) {
          bucket.hrAt = sample.to;
          bucket.hr = sample.value.round();
        }
      case SampleKind.hrv:
        bucket.hrvSum += sample.value;
        bucket.hrvCount++;
      case SampleKind.weight:
        if (bucket.weightAt == null || sample.to.isAfter(bucket.weightAt!)) {
          bucket.weightAt = sample.to;
          bucket.weight = sample.value;
        }
      case SampleKind.bodyFat:
        if (bucket.fatAt == null || sample.to.isAfter(bucket.fatAt!)) {
          bucket.fatAt = sample.to;
          bucket.fat = sample.value;
        }
      case SampleKind.leanMass:
        if (bucket.leanAt == null || sample.to.isAfter(bucket.leanAt!)) {
          bucket.leanAt = sample.to;
          bucket.lean = sample.value;
        }
      case SampleKind.sleepStage:
        bucket.stageMin += sample.value.round();
      case SampleKind.sleepUnspecified:
        bucket.unspecifiedMin += sample.value.round();
      case SampleKind.sleepSession:
        bucket.sessionMin += sample.value.round();
    }
  }

  if (stepsToday != null) {
    bucketFor(now).steps = stepsToday;
  }

  final days = buckets.values.map((bucket) => bucket.toDay()).where((day) => day.hasAny).toList()
    ..sort((a, b) => a.day.compareTo(b.day));
  final orderedWorkouts = [...workouts]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return HealthReading(
    days: days,
    workouts: orderedWorkouts,
    syncedAt: now,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    deviceNames: deviceNames,
  );
}

/// Sleep is attributed to the morning it ended. Other samples use the day
/// they started, which is how step and calorie buckets are stored.
DateTime _bucketDay(NormalizedSample sample) {
  final sleep = sample.kind == SampleKind.sleepStage ||
      sample.kind == SampleKind.sleepUnspecified ||
      sample.kind == SampleKind.sleepSession;
  if (!sleep) return dateOnly(sample.from);
  final end = sample.to;
  final atMidnight = end.hour == 0 && end.minute == 0 && end.second == 0 && end.millisecond == 0;
  if (atMidnight) return dateOnly(end.subtract(const Duration(days: 1)));
  return dateOnly(end);
}

class _DayBucket {
  _DayBucket(this.day);

  final DateTime day;
  int? steps;
  double? active;
  int? resting;
  DateTime? restingAt;
  int? hr;
  DateTime? hrAt;
  double hrvSum = 0;
  int hrvCount = 0;
  double? weight;
  DateTime? weightAt;
  double? fat;
  DateTime? fatAt;
  double? lean;
  DateTime? leanAt;
  int stageMin = 0;
  int unspecifiedMin = 0;
  int sessionMin = 0;

  /// Stages win when they exist, because a sleep session also counts time
  /// awake and an "asleep" total often repeats the same night.
  int? get sleepMinutes {
    if (stageMin > 0) return stageMin;
    if (unspecifiedMin > 0) return unspecifiedMin;
    if (sessionMin > 0) return sessionMin;
    return null;
  }

  HealthDay toDay() => HealthDay(
        day: day,
        steps: steps,
        activeKcal: active,
        restingHr: resting,
        heartRate: hr,
        sleepMinutes: sleepMinutes,
        hrvMs: hrvCount == 0 ? null : hrvSum / hrvCount,
        weightLb: weight,
        bodyFatPct: fat,
        leanMassLb: lean,
      );
}

List<HealthFlag> healthFlags({
  required List<HealthDay> days,
  required DateTime today,
  double? weightGoalLb,
}) {
  final flags = <HealthFlag>[];
  final sleep = _sleepFlag(days, dateOnly(today));
  if (sleep != null) flags.add(sleep);
  final weight = _weightFlag(days, dateOnly(today), weightGoalLb);
  if (weight != null) flags.add(weight);
  return flags;
}

int? _sleepOn(List<HealthDay> days, DateTime day) {
  for (final entry in days) {
    if (dateOnly(entry.day) == day) return entry.sleepMinutes;
  }
  return null;
}

HealthFlag? _sleepFlag(List<HealthDay> days, DateTime today) {
  final current = <int>[];
  final previous = <int>[];
  int? lastNight;
  for (var i = 0; i < 7; i++) {
    final night = _sleepOn(days, today.subtract(Duration(days: i)));
    if (night != null) {
      current.add(night);
      lastNight ??= night;
    }
    final before = _sleepOn(days, today.subtract(Duration(days: i + 7)));
    if (before != null) previous.add(before);
  }
  if (current.length < 3 || previous.length < 3 || lastNight == null) return null;
  final currentAvg = current.reduce((a, b) => a + b) / current.length;
  final previousAvg = previous.reduce((a, b) => a + b) / previous.length;
  if (previousAvg <= 0) return null;
  final drop = (previousAvg - currentAvg) / previousAvg;
  if (drop < 0.15) return null;
  final percent = (drop * 100).round();
  return HealthFlag(
    title: "Sleep is down $percent% this week",
    detail: "${formatSleep(lastNight)} last night · 7-day average was ${formatSleep(previousAvg.round())}",
  );
}

HealthFlag? _weightFlag(List<HealthDay> days, DateTime today, double? goal) {
  if (goal == null) return null;
  final start = today.subtract(const Duration(days: 30));
  HealthDay? latest;
  for (final day in days) {
    if (day.weightLb == null) continue;
    final when = dateOnly(day.day);
    if (when.isBefore(start) || when.isAfter(today)) continue;
    if (latest == null || when.isAfter(dateOnly(latest.day))) latest = day;
  }
  if (latest == null) return null;
  HealthDay? baseline;
  final earliestAllowed = dateOnly(latest.day).subtract(const Duration(days: 6));
  for (final day in days) {
    if (day.weightLb == null) continue;
    final when = dateOnly(day.day);
    if (when.isBefore(start) || !when.isBefore(earliestAllowed)) continue;
    if (baseline == null || when.isBefore(dateOnly(baseline.day))) baseline = day;
  }
  final current = latest.weightLb!;
  final delta = baseline == null ? null : current - baseline.weightLb!;
  final anchor = baseline?.weightLb ?? current;
  final goalIsLower = goal < anchor;
  final toward = delta != null && (goalIsLower ? delta <= -0.5 : delta >= 0.5);
  final close = (current - goal).abs() <= 1;
  final wrongWay = delta != null && delta.abs() >= 1 && (goalIsLower ? delta > 0 : delta < 0);
  if (!toward && !close && !wrongWay) return null;
  final change = (delta == null || delta.abs() < 0.1)
      ? ""
      : ", ${delta < 0 ? "down" : "up"} ${formatNumber(delta.abs())} lb in 30 days";
  final detail = "${formatNumber(current)} lb$change toward ${formatNumber(goal)}";
  if (toward || close) {
    return HealthFlag(title: "Weight is on target", detail: detail, onTarget: true);
  }
  return HealthFlag(title: "Weight is moving away from the goal", detail: detail);
}

String restingCaption(List<HealthDay> days, DateTime today) {
  final day = dateOnly(today);
  int? current;
  final prior = <int>[];
  for (final entry in days) {
    if (entry.restingHr == null) continue;
    final when = dateOnly(entry.day);
    if (when == day) {
      current = entry.restingHr;
    } else if (!when.isBefore(day.subtract(const Duration(days: 14))) && when.isBefore(day)) {
      prior.add(entry.restingHr!);
    }
  }
  if (current == null || prior.length < 3) return "bpm";
  prior.sort();
  final median = prior[prior.length ~/ 2];
  final diff = current - median;
  if (diff >= 5) return "Higher than usual";
  if (diff <= -5) return "Lower than usual";
  return "Typical";
}

List<double?> chartSeries({
  required List<HealthDay> days,
  required DateTime today,
  required int rangeDays,
  required double? Function(HealthDay day) read,
}) {
  final end = dateOnly(today);
  final start = end.subtract(Duration(days: rangeDays - 1));
  final values = <DateTime, double>{};
  for (final day in days) {
    final value = read(day);
    if (value == null) continue;
    final when = dateOnly(day.day);
    if (when.isBefore(start) || when.isAfter(end)) continue;
    values[when] = value;
  }
  if (values.length < 2) return const [];
  return [
    for (var i = 0; i < rangeDays; i++) values[start.add(Duration(days: i))],
  ];
}

List<HealthTrendLine> healthTrendLines({
  required List<HealthDay> days,
  required DateTime today,
  int rangeDays = 30,
  double? weightGoalLb,
  int stepGoal = kDailyStepGoal,
}) {
  final lines = <HealthTrendLine>[];
  final weight = _span(days, today, rangeDays, (day) => day.weightLb);
  if (weight != null) {
    final value = weightGoalLb == null
        ? "${formatNumber(weight.end)} lb"
        : "${formatNumber(weight.end)} of ${formatNumber(weightGoalLb)} lb";
    lines.add(HealthTrendLine(label: "Weight", value: value, delta: _delta(weight, rangeDays, "lb")));
  }
  final fat = _span(days, today, rangeDays, (day) => day.bodyFatPct);
  if (fat != null) {
    lines.add(HealthTrendLine(label: "Body fat", value: "${formatNumber(fat.end)}%", delta: _delta(fat, rangeDays, "pts")));
  }
  final lean = _span(days, today, rangeDays, (day) => day.leanMassLb);
  if (lean != null) {
    lines.add(HealthTrendLine(label: "Lean mass", value: "${formatNumber(lean.end)} lb", delta: _delta(lean, rangeDays, "lb")));
  }
  final todaySteps = _stepsOn(days, today);
  if (todaySteps != null) {
    lines.add(HealthTrendLine(
      label: "Steps",
      value: "${formatCount(todaySteps)} of ${formatCount(stepGoal)} today",
    ));
  }
  return lines;
}

int? _stepsOn(List<HealthDay> days, DateTime today) {
  for (final day in days) {
    if (dateOnly(day.day) == dateOnly(today)) return day.steps;
  }
  return null;
}

class _Span {
  const _Span(this.start, this.end);
  final double start;
  final double end;
}

_Span? _span(List<HealthDay> days, DateTime today, int rangeDays, double? Function(HealthDay day) read) {
  final endDay = dateOnly(today);
  final startDay = endDay.subtract(Duration(days: rangeDays));
  HealthDay? first;
  HealthDay? last;
  for (final day in days) {
    final value = read(day);
    if (value == null) continue;
    final when = dateOnly(day.day);
    if (when.isBefore(startDay) || when.isAfter(endDay)) continue;
    if (first == null || when.isBefore(dateOnly(first.day))) first = day;
    if (last == null || when.isAfter(dateOnly(last.day))) last = day;
  }
  if (last == null) return null;
  final end = read(last);
  if (end == null) return null;
  final start = first == null ? null : read(first);
  return _Span(start ?? end, end);
}

String? _delta(_Span span, int rangeDays, String unit) {
  final change = span.end - span.start;
  if (change.abs() < 0.05) return null;
  final sign = change > 0 ? "+" : "−";
  final suffix = unit == "lb" ? "" : " $unit";
  return "${rangeDays}d $sign${formatNumber(change.abs())}$suffix";
}
