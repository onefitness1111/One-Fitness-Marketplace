import "dart:convert";
import "dart:typed_data";

import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "../../../core/utils/food_catalog.dart";
import "../../../core/utils/nutrition_helpers.dart";
import "../../../core/utils/photo_picker_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/meal_def.dart";
import "../../../data/models/nutrition_plan.dart";

/// A meal the client builds for themselves: a photo, ingredients with
/// amounts, cooking steps, diet tags, and totals that come from the
/// ingredients. Saving does not publish it to the shared library.
class AddMealScreen extends StatefulWidget {
  const AddMealScreen({super.key, required this.mealType, required this.label});

  final String mealType;
  final String label;

  @override
  State<AddMealScreen> createState() => _AddMealScreenState();
}

class _Line {
  _Line();
  final search = TextEditingController();
  final qty = TextEditingController(text: "1");
  FoodItem? food;

  void dispose() {
    search.dispose();
    qty.dispose();
  }
}

class _AddMealScreenState extends State<AddMealScreen> {
  final _name = TextEditingController();
  final _steps = TextEditingController();
  final _lines = <_Line>[_Line()];
  final _tags = <String>{};
  Uint8List? _photo;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _steps.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  List<Ingredient> get _ingredients {
    return [
      for (final line in _lines)
        if (line.food != null)
          Ingredient(
            item: line.food!.name,
            qty: double.tryParse(line.qty.text.trim()) ?? 0,
            unit: line.food!.unit,
            category: "pantry",
            macros: line.food!.perUnit,
          ),
    ].where((ing) => (ing.qty ?? 0) > 0).toList();
  }

  Future<void> _pickPhoto(bool camera) async {
    final bytes = await pickPlatePhotoBytes(camera: camera);
    if (bytes != null && mounted) setState(() => _photo = bytes);
  }

  void _save() {
    final name = _name.text.trim();
    final ingredients = _ingredients;
    if (name.isEmpty) {
      setState(() => _err = "Give the meal a name.");
      return;
    }
    if (ingredients.isEmpty) {
      setState(() => _err = "Add at least one ingredient with an amount.");
      return;
    }
    final macros = computeMacrosFromIngredients(ingredients);
    final tags = _tags.isEmpty ? const ["omnivore"] : _tags.toList();
    Navigator.of(context).pop(MealDef(
      id: "mine-${DateTime.now().microsecondsSinceEpoch}",
      name: name,
      mealType: widget.mealType,
      calories: macros?.calories ?? 0,
      protein: macros?.protein ?? 0,
      carbs: macros?.carbs ?? 0,
      fats: macros?.fats ?? 0,
      ingredients: ingredients,
      instructions: _steps.text.trim().isEmpty ? null : _steps.text.trim(),
      dietTags: tags,
      isCustom: true,
      photoDataUrl: _photo == null ? null : "data:image/jpeg;base64,${base64Encode(_photo!)}",
    ));
  }

  @override
  Widget build(BuildContext context) {
    final macros = computeMacrosFromIngredients(_ingredients);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            BackBar(onBack: () => Navigator.of(context).pop(), title: "Add ${widget.label.toLowerCase()}"),
            const SizedBox(height: 8),
            Text(
              "Ingredients you add here are included in your grocery list. The totals come from those ingredients.",
              style: TextStyle(fontSize: 12.5, color: AppColors.mute, height: 1.4),
            ),
            const SizedBox(height: 14),
            FieldLabeled(label: "Meal name", child: AppField(kind: FieldKind.name, controller: _name, placeholder: "e.g. Chicken rice bowl")),
            const SizedBox(height: 14),
            const SectionLabel("Photo"),
            if (_photo != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(_photo!, height: 160, width: double.infinity, fit: BoxFit.cover),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: () => _pickPhoto(true), child: const Text("Take photo"))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(onPressed: () => _pickPhoto(false), child: const Text("Choose photo"))),
              ],
            ),
            const SizedBox(height: 16),
            const SectionLabel("Ingredients"),
            ..._lines.map((line) => _IngredientEditor(
                  line: line,
                  canRemove: _lines.length > 1,
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() {
                    line.dispose();
                    _lines.remove(line);
                  }),
                )),
            TextButton.icon(
              onPressed: () => setState(() => _lines.add(_Line())),
              icon: Icon(Icons.add, size: 16, color: AppColors.gold),
              label: Text("Add ingredient", style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700)),
            ),
            if (macros != null) ...[
              const SizedBox(height: 6),
              Text(
                "${macros.calories} kcal · P ${fmtQty(macros.protein)}g · C ${fmtQty(macros.carbs)}g · F ${fmtQty(macros.fats)}g",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.txt),
              ),
              Text("Calculated from the ingredients.", style: TextStyle(fontSize: 11.5, color: AppColors.mute)),
            ],
            const SizedBox(height: 16),
            const SectionLabel("Cooking steps"),
            TextField(
              controller: _steps,
              maxLines: 5,
              style: TextStyle(color: AppColors.txt, fontSize: 13),
              decoration: InputDecoration(
                hintText: "What to do, step by step",
                hintStyle: TextStyle(color: AppColors.mute),
                filled: true,
                fillColor: AppColors.card,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line)),
              ),
            ),
            const SizedBox(height: 16),
            const SectionLabel("Diet tags"),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in kClientDietFilters)
                  if (tag.$1.isNotEmpty)
                    _TagChip(
                      label: tag.$2,
                      on: _tags.contains(tag.$1),
                      onTap: () => setState(() => _tags.contains(tag.$1) ? _tags.remove(tag.$1) : _tags.add(tag.$1)),
                    ),
              ],
            ),
            if (_err != null) ...[
              const SizedBox(height: 12),
              Text(_err!, style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ],
            const SizedBox(height: 16),
            BtnGold(full: true, onPressed: _save, child: const Text("Save meal")),
          ],
        ),
      ),
    );
  }
}

class _IngredientEditor extends StatelessWidget {
  const _IngredientEditor({
    required this.line,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final _Line line;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hits = line.food == null ? searchFoods(line.search.text).take(6).toList() : const <FoodItem>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (line.food == null)
              AppField(
                kind: FieldKind.search,
                controller: line.search,
                placeholder: "Search foods",
                onChanged: (_) => onChanged(),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(line.food!.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  TextButton(
                    onPressed: () {
                      line.food = null;
                      line.search.clear();
                      onChanged();
                    },
                    child: Text("Change", style: TextStyle(color: AppColors.mute, fontSize: 12)),
                  ),
                ],
              ),
            if (hits.isNotEmpty)
              ...hits.map((food) => InkWell(
                    onTap: () {
                      line.food = food;
                      line.search.text = food.name;
                      onChanged();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        "${food.name} · ${fmtQty(food.calories)} kcal per ${food.unit}",
                        style: TextStyle(fontSize: 12.5, color: AppColors.txt),
                      ),
                    ),
                  )),
            if (line.food != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: AppField(
                      controller: line.qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(line.food!.unit, style: TextStyle(color: AppColors.mute)),
                  const Spacer(),
                  if (canRemove)
                    IconButton(
                      onPressed: onRemove,
                      icon: Icon(Icons.close, size: 18, color: AppColors.danger),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppColors.gold : AppColors.card,
          border: Border.all(color: on ? AppColors.gold : AppColors.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(label, style: TextStyle(fontSize: 11.5, color: on ? AppColors.onGold : AppColors.mute, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
