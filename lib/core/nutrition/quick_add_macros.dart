import "../../data/models/food_log.dart";
import "../utils/food_catalog.dart";

/// Shown when a name-and-calories estimate cannot be made. The client can
/// type the missing macros or log the numbers they already entered.
const quickAddEstimateFailedMessage =
    "Couldn't estimate the missing numbers. Type them in, or log what you entered.";

/// Protein, carbs, and fat for one Quick add line.
///
/// [estimated] is true when at least one macro was left blank and then
/// filled in. Typing all three macros leaves it false.
class QuickAddMacros {
  const QuickAddMacros({
    required this.protein,
    required this.carbs,
    required this.fats,
    required this.estimated,
  });

  final double protein;
  final double carbs;
  final double fats;
  final bool estimated;

  double get macroCalories => 4 * protein + 4 * carbs + 9 * fats;
}

/// Empty, or not a number, means the client left the field blank.
/// `0` is a typed zero and is kept.
double? readQuickAddMacro(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  return double.tryParse(text);
}

String formatQuickAddGrams(double grams) {
  if (!grams.isFinite || grams <= 0) return "0";
  final rounded = (grams * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return rounded.toInt().toString();
  return rounded.toStringAsFixed(1);
}

/// Fills blank macros from a known food on the search list.
///
/// Returns null when the name is not a close match and the phone should
/// ask the server. Calories the client typed are not changed. A typed
/// macro is copied through even when the known food disagrees.
QuickAddMacros? localQuickAddMacros({
  required String name,
  required int calories,
  double? protein,
  double? carbs,
  double? fats,
}) {
  if (protein != null && carbs != null && fats != null) {
    return QuickAddMacros(
      protein: protein,
      carbs: carbs,
      fats: fats,
      estimated: false,
    );
  }
  if (calories == 0) {
    return QuickAddMacros(
      protein: protein ?? 0,
      carbs: carbs ?? 0,
      fats: fats ?? 0,
      estimated: true,
    );
  }
  if (calories < 0) return null;
  final food = matchFoodClosely(name);
  if (food == null) return null;
  return mergeQuickAddMacros(
    calories: calories,
    protein: protein,
    carbs: carbs,
    fats: fats,
    sourceProtein: food.protein,
    sourceCarbs: food.carbs,
    sourceFats: food.fats,
  );
}

/// Keeps every typed macro and fills the blanks from [sourceProtein],
/// [sourceCarbs], and [sourceFats].
///
/// The source is a ratio, not a serving. Blank macros are scaled so
/// `4P + 4C + 9F` stays close to [calories] when those blanks can absorb
/// the difference. Typed numbers are never replaced. Returns null when
/// the source has no grams to scale from.
QuickAddMacros? mergeQuickAddMacros({
  required int calories,
  double? protein,
  double? carbs,
  double? fats,
  required double sourceProtein,
  required double sourceCarbs,
  required double sourceFats,
}) {
  if (protein != null && carbs != null && fats != null) {
    return QuickAddMacros(
      protein: protein,
      carbs: carbs,
      fats: fats,
      estimated: false,
    );
  }
  final typed = <double?>[protein, carbs, fats];
  final source = <double>[sourceProtein, sourceCarbs, sourceFats];
  if (source.every((grams) => !grams.isFinite || grams <= 0)) return null;

  final blank = <bool>[protein == null, carbs == null, fats == null];
  var typedKcal = 0.0;
  var sourceBlankKcal = 0.0;
  for (var i = 0; i < 3; i++) {
    if (!blank[i]) {
      typedKcal += _perGram[i] * typed[i]!;
    } else if (source[i].isFinite && source[i] > 0) {
      sourceBlankKcal += _perGram[i] * source[i];
    }
  }

  final grams = List<double>.filled(3, 0);
  final adjustable = List<bool>.filled(3, false);
  final remain = calories - typedKcal;
  final scale = sourceBlankKcal > 0 && remain > 0
      ? remain / sourceBlankKcal
      : 0.0;
  for (var i = 0; i < 3; i++) {
    if (!blank[i]) {
      grams[i] = typed[i]!;
      continue;
    }
    if (scale <= 0 || !source[i].isFinite || source[i] <= 0) {
      grams[i] = 0;
      continue;
    }
    grams[i] = _round1(source[i] * scale);
    adjustable[i] = grams[i] > 0;
  }
  if (scale > 0) _closeCalorieGap(grams, adjustable, calories);

  return QuickAddMacros(
    protein: grams[0],
    carbs: grams[1],
    fats: grams[2],
    estimated: true,
  );
}

/// Builds the logged line. An estimate uses an id starting with `est-`
/// so the log shows Estimated. Typing all three macros uses `log-`.
FoodLogItem foodLogItemFromQuickAdd({
  required String name,
  required int calories,
  required QuickAddMacros macros,
  required String idSuffix,
}) {
  return FoodLogItem(
    id: "${macros.estimated ? "est" : "log"}-$idSuffix",
    name: name,
    qty: 1,
    unit: "serving",
    calories: calories,
    protein: macros.protein,
    carbs: macros.carbs,
    fats: macros.fats,
  );
}

/// Reads a server estimate as a ratio and merges it with what was typed.
/// Returns null when the response is not a usable estimate.
QuickAddMacros? macrosFromServerEstimate({
  required int calories,
  double? protein,
  double? carbs,
  double? fats,
  required Map<String, dynamic> response,
}) {
  if (response["ok"] != true) return null;
  return mergeQuickAddMacros(
    calories: calories,
    protein: protein,
    carbs: carbs,
    fats: fats,
    sourceProtein: (response["protein"] as num?)?.toDouble() ?? 0,
    sourceCarbs: (response["carbs"] as num?)?.toDouble() ?? 0,
    sourceFats: (response["fats"] as num?)?.toDouble() ?? 0,
  );
}

const _perGram = <double>[4, 4, 9];

double _round1(double n) {
  if (!n.isFinite || n <= 0) return 0;
  return (n * 10).round() / 10;
}

/// Rounding each gram can miss the typed calories by a fraction of a gram.
/// Nudge one filled macro when the gap is only that rounding error.
void _closeCalorieGap(List<double> grams, List<bool> adjustable, int calories) {
  final gap = calories - (4 * grams[0] + 4 * grams[1] + 9 * grams[2]);
  if (gap.abs() < 0.4 || gap.abs() > 2) return;
  for (var i = 0; i < 3; i++) {
    if (!adjustable[i] || grams[i] <= 0) continue;
    final next = _round1(grams[i] + gap / _perGram[i]);
    if (next <= 0) continue;
    grams[i] = next;
    return;
  }
}
