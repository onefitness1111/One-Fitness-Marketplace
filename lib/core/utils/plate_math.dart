/// Plates on one side of a barbell.
///
/// The bar is 45 lb. Plates are 45, 35, 25, 10, 5, and 2.5, largest first.
class PlatePlan {
  const PlatePlan({required this.perSide, this.tooLight = false, this.remainder = 0});

  /// One of each plate to load on each side, largest first.
  final List<double> perSide;

  /// The weight is under the bar, so no plates are added.
  final bool tooLight;

  /// Pounds left on each side that those plates cannot make.
  final double remainder;

  String get label {
    if (tooLight) return "That's lighter than the 45 lb bar.";
    if (perSide.isEmpty && remainder == 0) return "Just the 45 lb bar.";
    final plates = perSide.map(_lb).join(" + ");
    final extra = remainder > 0 ? " ($_lb left over on each side)" : "";
    if (plates.isEmpty) return "No standard plate fits.$extra";
    return "Per side: $plates$extra";
  }
}

const barWeightLb = 45.0;
const plateSizesLb = [45.0, 35.0, 25.0, 10.0, 5.0, 2.5];

/// How to load [totalLb] on a barbell, the same plates on each side.
PlatePlan platesPerSide(double totalLb) {
  if (totalLb + 0.01 < barWeightLb) {
    return const PlatePlan(perSide: [], tooLight: true);
  }
  var side = (totalLb - barWeightLb) / 2;
  final used = <double>[];
  for (final plate in plateSizesLb) {
    while (side + 0.001 >= plate) {
      used.add(plate);
      side -= plate;
    }
  }
  if (side < 0.05) side = 0;
  return PlatePlan(perSide: used, remainder: side);
}

String _lb(double n) => n % 1 == 0 ? "${n.toInt()}" : n.toString();
