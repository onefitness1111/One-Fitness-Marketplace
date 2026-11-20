import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_places.dart";

/// "Location" at the top of booking. Tap it to pick a place or all of them.
class BookingLocationSwitcher extends StatelessWidget {
  const BookingLocationSwitcher({
    super.key,
    required this.places,
    required this.selectedId,
    required this.onSelect,
  });

  final List<BookablePlace> places;

  /// Null is "All locations".
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  BookablePlace? get _selected {
    for (final place in places) {
      if (place.id == selectedId) return place;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (places.isEmpty) return const SizedBox.shrink();
    final selected = _selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: AppColors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Text("Location", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.mute)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    selected?.label ?? "All locations",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.txt),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.expand_more, size: 18, color: AppColors.txt),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          children: [
            _Choice(
              label: "All locations",
              address: "Every coach and session",
              selected: selectedId == null || _selected == null,
              onTap: () => Navigator.pop(ctx, bookingPlaceAll),
            ),
            for (final place in places)
              _Choice(
                label: place.label,
                address: place.address,
                selected: place.id == selectedId,
                onTap: () => Navigator.pop(ctx, place.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    onSelect(picked == bookingPlaceAll ? null : picked);
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.address, required this.selected, required this.onTap});

  final String label;
  final String address;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedTileColor: AppColors.bg,
      title: Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.txt)),
      subtitle: address.isEmpty ? null : Text(address, style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35)),
      trailing: selected ? Icon(Icons.check, size: 18, color: AppColors.txt) : null,
    );
  }
}
