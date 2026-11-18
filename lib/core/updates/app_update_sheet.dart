import "package:flutter/material.dart";
import "package:url_launcher/url_launcher.dart";
import "../theme/app_colors.dart";
import "../widgets/widgets.dart";
import "app_update.dart";

/// The optional sheet and the blocking screen for an old install.
class AppUpdateNotice extends StatelessWidget {
  const AppUpdateNotice({super.key, required this.config, required this.blocking, this.onDismiss});

  final AppUpdateConfig config;
  final bool blocking;
  final VoidCallback? onDismiss;

  Future<void> _open() async {
    if (!appStoreLinkReady(config.appStoreUrl)) return;
    final uri = Uri.tryParse(config.appStoreUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final linkReady = appStoreLinkReady(config.appStoreUrl);
    return Material(
      color: AppColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                config.message,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.txt, fontSize: 18, fontWeight: FontWeight.w800, height: 1.35),
              ),
              const SizedBox(height: 8),
              Text(
                blocking
                    ? "This version of the app can't be used until it's updated."
                    : "You can keep using this version for now.",
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 20),
              BtnGold(
                full: true,
                onPressed: linkReady ? _open : null,
                child: const Text("Update now"),
              ),
              if (!linkReady)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    "The App Store link isn't in yet.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mute, fontSize: 12),
                  ),
                ),
              if (!blocking && onDismiss != null) ...[
                const SizedBox(height: 8),
                BtnGhost(full: true, onPressed: onDismiss, child: const Text("Not now")),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
