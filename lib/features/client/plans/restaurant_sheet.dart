import "package:flutter/material.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/meal_resize.dart";
import "../../../core/utils/nutrition_helpers.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/food_log.dart";
import "../../../core/utils/ai_visibility.dart";

/// Search a restaurant by its Google Maps name and pick a suggestion that
/// fits this meal. The numbers are labeled Estimate.
Future<FoodLogItem?> showRestaurantSheet(
  BuildContext context, {
  required String slot,
  required String label,
  required SlotBudget budget,
}) {
  return showModalBottomSheet<FoodLogItem>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.78,
        child: _RestaurantBody(slot: slot, label: label, budget: budget),
      ),
    ),
  );
}

class _Place {
  const _Place({required this.id, required this.name, required this.address});
  final String id;
  final String name;
  final String address;
}

class _RestaurantBody extends StatefulWidget {
  const _RestaurantBody({required this.slot, required this.label, required this.budget});
  final String slot;
  final String label;
  final SlotBudget budget;

  @override
  State<_RestaurantBody> createState() => _RestaurantBodyState();
}

class _RestaurantBodyState extends State<_RestaurantBody> {
  final _query = TextEditingController();
  var _busy = false;
  String? _error;
  List<_Place> _places = const [];
  _Place? _picked;
  List<FoodLogItem> _items = const [];

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _budgetBody => {
        "slot": widget.slot,
        if (widget.budget.calories != null) "calories": widget.budget.calories,
        if (widget.budget.protein != null) "protein": widget.budget.protein,
        if (widget.budget.carbs != null) "carbs": widget.budget.carbs,
        if (widget.budget.fats != null) "fats": widget.budget.fats,
      };

  String _safe(Object e) {
    final text = e.toString().replaceFirst("Exception: ", "");
    return clientSafeText(text, fallback: "That didn't work. Try again.");
  }

  Future<void> _search() async {
    final name = _query.text.trim();
    if (name.length < 2) {
      setState(() => _error = "Type the restaurant's name.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _picked = null;
      _items = const [];
    });
    try {
      final res = await SupabaseService.recommendRestaurant({"query": name, ..._budgetBody});
      if (res["ok"] != true) throw Exception(res["error"] ?? "Couldn't search right now.");
      final places = _placesFrom(res["places"]);
      final items = _itemsFrom(res["items"]);
      if (!mounted) return;
      setState(() {
        _places = places;
        _picked = places.length == 1 ? places.first : null;
        _items = items;
        if (places.isEmpty) _error = "No restaurant matched that name.";
      });
    } catch (e) {
      if (mounted) setState(() => _error = _safe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(_Place place) async {
    setState(() {
      _busy = true;
      _error = null;
      _picked = place;
      _items = const [];
    });
    try {
      final res = await SupabaseService.recommendRestaurant({
        "placeId": place.id,
        "placeName": place.name,
        "address": place.address,
        ..._budgetBody,
      });
      if (res["ok"] != true) throw Exception(res["error"] ?? "Couldn't find menu items.");
      if (!mounted) return;
      setState(() => _items = _itemsFrom(res["items"]));
      if (_items.isEmpty && mounted) {
        setState(() => _error = "Nothing from that menu fit this meal's budget.");
      }
    } catch (e) {
      if (mounted) setState(() => _error = _safe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<_Place> _placesFrom(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map)
          _Place(
            id: row["id"]?.toString() ?? "",
            name: row["name"]?.toString() ?? "",
            address: row["address"]?.toString() ?? "",
          ),
    ].where((p) => p.name.isNotEmpty).toList();
  }

  List<FoodLogItem> _itemsFrom(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map)
          FoodLogItem(
            id: "rest-${row["name"]}-${row["calories"]}",
            name: row["name"]?.toString() ?? "",
            qty: 1,
            unit: "serving",
            calories: (row["calories"] as num?)?.round() ?? 0,
            protein: (row["protein"] as num?)?.toDouble() ?? 0,
            carbs: (row["carbs"] as num?)?.toDouble() ?? 0,
            fats: (row["fats"] as num?)?.toDouble() ?? 0,
          ),
    ].where((item) => item.name.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final budget = widget.budget.calories;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel("Restaurant · ${widget.label}"),
          Text(
            budget == null
                ? "Search the restaurant by its map name."
                : "Search the restaurant by its map name. Suggestions stay around $budget kcal.",
            style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppField(
                  kind: FieldKind.search,
                  controller: _query,
                  placeholder: "Restaurant name",
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              BtnGold(onPressed: _busy ? null : _search, child: const Text("Search")),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
          ],
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                if (_picked == null)
                  ..._places.map((place) => AppCard(
                        onTap: _busy ? null : () => _choose(place),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(place.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            if (place.address.isNotEmpty)
                              Text(place.address, style: TextStyle(fontSize: 12, color: AppColors.mute)),
                          ],
                        ),
                      )),
                if (_picked != null) ...[
                  Text(_picked!.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  if (_picked!.address.isNotEmpty)
                    Text(_picked!.address, style: TextStyle(fontSize: 12, color: AppColors.mute)),
                  const SizedBox(height: 8),
                  Text("Estimate", style: TextStyle(fontSize: 11, color: AppColors.gold, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  ..._items.map((item) => AppCard(
                        onTap: () => Navigator.of(context).pop(item.copyWith(
                          id: "rest-${DateTime.now().microsecondsSinceEpoch}",
                        )),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              "${item.calories} kcal · P ${fmtQty(item.protein)} · C ${fmtQty(item.carbs)} · F ${fmtQty(item.fats)}",
                              style: TextStyle(fontSize: 12, color: AppColors.mute),
                            ),
                          ],
                        ),
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
