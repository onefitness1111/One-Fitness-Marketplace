import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "../theme/app_colors.dart";
import "../utils/chat_channels.dart";
import "widgets.dart";

/// The "Send via — pick any" row from new chat: In app, SMS, and Email.
/// Any combination can be on. The last chip stays on, so a send always
/// has somewhere to go.
class SendViaChips extends StatelessWidget {
  const SendViaChips({
    super.key,
    required this.channels,
    required this.onChanged,
    this.hidden = const {},
  });

  final Set<ChatChannel> channels;
  final ValueChanged<Set<ChatChannel>> onChanged;

  /// Channels that are not offered. The business contact has no SMS.
  final Set<ChatChannel> hidden;

  @override
  Widget build(BuildContext context) {
    final shown = [for (final ch in chatChannelOrder) if (!hidden.contains(ch)) ch];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Send via — pick any",
          style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: _Chip(
                  label: chatChannelLabels[shown[i]]!,
                  selected: channels.contains(shown[i]),
                  onTap: () => onChanged(toggleChannel(channels, shown[i])),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.onGold : AppColors.mute;
    return Semantics(
      checked: selected,
      child: TapHighlight(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.gold : AppColors.card,
            border: Border.all(color: selected ? AppColors.gold : AppColors.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? LucideIcons.check : LucideIcons.plus, size: 12, color: fg),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
