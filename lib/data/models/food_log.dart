import "nutrition_plan.dart";

/// One line in the client's own food log. Totals are for this line as
/// logged (quantity already applied), not per single unit.
class FoodLogItem {
  const FoodLogItem({
    required this.id,
    required this.name,
    required this.qty,
    required this.unit,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fats,
  });

  final String id;
  final String name;
  final double qty;
  final String unit;
  final int calories;
  final double protein;
  final double carbs;
  final double fats;

  FoodLogItem copyWith({String? id}) => FoodLogItem(
        id: id ?? this.id,
        name: name,
        qty: qty,
        unit: unit,
        calories: calories,
        protein: protein,
        carbs: carbs,
        fats: fats,
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "qty": qty,
        "unit": unit,
        "calories": calories,
        "protein": protein,
        "carbs": carbs,
        "fats": fats,
      };

  static FoodLogItem? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final name = (j["name"] as String? ?? "").trim();
    if (name.isEmpty) return null;
    return FoodLogItem(
      id: j["id"]?.toString() ?? "",
      name: name,
      qty: (j["qty"] as num?)?.toDouble() ?? 1,
      unit: j["unit"] as String? ?? "",
      calories: (j["calories"] as num?)?.round() ?? 0,
      protein: (j["protein"] as num?)?.toDouble() ?? 0,
      carbs: (j["carbs"] as num?)?.toDouble() ?? 0,
      fats: (j["fats"] as num?)?.toDouble() ?? 0,
    );
  }
}

/// The client's food log only. It never holds a coach's meal plan.
///
/// [days] is `yyyy-MM-dd` -> slot (`breakfast`, `lunch`, `dinner`,
/// `snacks`, `smoothies`) -> lines. [recents] is the newest foods first.
class FoodLog {
  const FoodLog({this.days = const {}, this.recents = const []});

  final Map<String, Map<String, List<FoodLogItem>>> days;
  final List<FoodLogItem> recents;

  List<FoodLogItem> lines(String date, String slot) => days[date]?[slot] ?? const [];

  MacroSnapshot totalsFor(String date) {
    var calories = 0;
    var protein = 0.0, carbs = 0.0, fats = 0.0;
    for (final slot in days[date]?.values ?? const <List<FoodLogItem>>[]) {
      for (final line in slot) {
        calories += line.calories;
        protein += line.protein;
        carbs += line.carbs;
        fats += line.fats;
      }
    }
    return MacroSnapshot(calories: calories, protein: protein, carbs: carbs, fats: fats);
  }

  MacroSnapshot totalsForSlot(String date, String slot) {
    var calories = 0;
    var protein = 0.0, carbs = 0.0, fats = 0.0;
    for (final line in lines(date, slot)) {
      calories += line.calories;
      protein += line.protein;
      carbs += line.carbs;
      fats += line.fats;
    }
    return MacroSnapshot(calories: calories, protein: protein, carbs: carbs, fats: fats);
  }

  FoodLog add(String date, String slot, FoodLogItem item) {
    final day = {...?days[date]};
    day[slot] = [...?day[slot], item];
    final recents = [
      item,
      ...this.recents.where((r) => r.name.toLowerCase() != item.name.toLowerCase()),
    ].take(15).toList();
    return FoodLog(days: {...days, date: day}, recents: recents);
  }

  FoodLog remove(String date, String slot, String id) {
    final day = {...?days[date]};
    day[slot] = [...?day[slot]].where((line) => line.id != id).toList();
    return FoodLog(days: {...days, date: day}, recents: recents);
  }

  Map<String, dynamic> toJson() => {
        "days": {
          for (final day in days.entries)
            day.key: {
              for (final slot in day.value.entries) slot.key: slot.value.map((e) => e.toJson()).toList(),
            },
        },
        "recents": recents.map((e) => e.toJson()).toList(),
      };

  static FoodLog fromJson(dynamic raw) {
    if (raw is! Map) return const FoodLog();
    final j = raw.cast<String, dynamic>();
    final daysRaw = j["days"];
    final days = <String, Map<String, List<FoodLogItem>>>{};
    if (daysRaw is Map) {
      for (final day in daysRaw.entries) {
        if (day.value is! Map) continue;
        final slots = <String, List<FoodLogItem>>{};
        for (final slot in (day.value as Map).entries) {
          if (slot.value is! List) continue;
          slots[slot.key.toString()] = [
            for (final line in slot.value as List)
              if (FoodLogItem.fromJson(line) case final item?) item,
          ];
        }
        days[day.key.toString()] = slots;
      }
    }
    final recentsRaw = j["recents"];
    return FoodLog(
      days: days,
      recents: recentsRaw is List
          ? recentsRaw.map(FoodLogItem.fromJson).whereType<FoodLogItem>().toList()
          : const [],
    );
  }
}

String foodLogDate(DateTime day) {
  final y = day.year.toString().padLeft(4, "0");
  final m = day.month.toString().padLeft(2, "0");
  final d = day.day.toString().padLeft(2, "0");
  return "$y-$m-$d";
}
