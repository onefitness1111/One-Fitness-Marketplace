import "package:flutter/material.dart";

import "../../data/models/comm_message.dart";
import "../theme/app_colors.dart";

/// Tap picks a heart. Long-press opens heart, thumbs-up, and report.
Future<String?> showMessageActions(
  BuildContext context, {
  required bool canReport,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text("❤️  Heart"),
            onTap: () => Navigator.of(ctx).pop("heart"),
          ),
          ListTile(
            title: const Text("👍  Thumbs up"),
            onTap: () => Navigator.of(ctx).pop("thumb"),
          ),
          if (canReport)
            ListTile(
              title: const Text("Report"),
              onTap: () => Navigator.of(ctx).pop("report"),
            ),
        ],
      ),
    ),
  );
}

class ReactionMarks extends StatelessWidget {
  const ReactionMarks({super.key, required this.reactions});

  final List<MessageReaction> reactions;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final hearts = reactions.where((r) => r.reaction != "thumb").length;
    final thumbs = reactions.where((r) => r.reaction == "thumb").length;
    final parts = <String>[
      if (hearts > 0) hearts == 1 ? "❤️" : "❤️ $hearts",
      if (thumbs > 0) thumbs == 1 ? "👍" : "👍 $thumbs",
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(parts.join("  "), style: const TextStyle(fontSize: 12)),
    );
  }
}
