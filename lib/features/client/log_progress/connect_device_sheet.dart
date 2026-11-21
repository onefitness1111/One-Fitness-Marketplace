import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "../../../core/health/health_stats.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/app_card.dart";

/// Explains the source, then returns its id. The system permission sheet
/// is the caller's next step, and only for an option that can actually connect.
Future<String?> showConnectDeviceSheet(BuildContext context, {required HealthPlatform platform}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => ConnectDeviceSheet(platform: platform),
  );
}

class ConnectDeviceSheet extends StatelessWidget {
  const ConnectDeviceSheet({super.key, required this.platform});

  final HealthPlatform platform;

  @override
  Widget build(BuildContext context) {
    final options = connectOptions(platform);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(height: 14),
            const Text("Connect a device", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              "Choose a source. This is read only, and your coach sees nothing until you turn sharing on.",
              style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.mute),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _OptionTile(option: options[i]),
            ],
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Not now"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.option});

  final ConnectOption option;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon(option.id), size: 18, color: AppColors.txt),
              const SizedBox(width: 8),
              Expanded(child: Text(option.title, style: const TextStyle(fontWeight: FontWeight.w800))),
              if (option.comingSoon)
                Container(
                  key: const Key("fitbit-coming-soon"),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text("Coming soon", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.mute)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(option.body, style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.mute)),
          if (option.canConnect) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key("connect-${option.id}"),
                onPressed: () => Navigator.pop(context, option.id),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.txt,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(option.actionLabel!, style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _icon(String id) => switch (id) {
        "apple_health" => LucideIcons.apple,
        "apple_watch" => LucideIcons.watch,
        "health_connect" => LucideIcons.smartphone,
        "fitbit" => LucideIcons.activity,
        "samsung" => LucideIcons.smartphone,
        _ => LucideIcons.circle,
      };
}
