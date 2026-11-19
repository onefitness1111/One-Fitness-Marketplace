/// A target the client set on Log Progress: a body weight, an inch
/// measurement, or a lift. Kept on their record, not on the dashboard.
class ProgressGoal {
  const ProgressGoal({
    required this.kind,
    required this.field,
    required this.target,
    this.start,
    this.unit = "lb",
  });

  /// "weight", "inches", or "lift".
  final String kind;

  /// "weight", "waist", "chest", "hips", "arms", "thighs", or an exercise name.
  final String field;
  final double target;

  /// Where they started when they set the goal. The bar measures from here.
  final double? start;
  final String unit;

  String get label => switch (kind) {
        "weight" => "Goal weight",
        "inches" => switch (field) {
            "chest" => "Chest",
            "waist" => "Waist",
            "hips" => "Hips",
            "arms" => "Arms",
            "thighs" => "Thighs",
            _ => "Inches",
          },
        _ => field.isEmpty ? "Lift" : field,
      };

  Map<String, dynamic> toJson() => {
        "kind": kind,
        "field": field,
        "target": target,
        if (start != null) "start": start,
        "unit": unit,
      };

  static ProgressGoal? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final kind = raw["kind"]?.toString() ?? "";
    final field = raw["field"]?.toString() ?? "";
    final target = raw["target"];
    final number = target is num ? target.toDouble() : double.tryParse("$target");
    if (kind.isEmpty || number == null) return null;
    final startRaw = raw["start"];
    final start = startRaw is num ? startRaw.toDouble() : double.tryParse("${startRaw ?? ""}");
    return ProgressGoal(
      kind: kind,
      field: field,
      target: number,
      start: start,
      unit: raw["unit"]?.toString().isNotEmpty == true ? raw["unit"].toString() : "lb",
    );
  }
}
