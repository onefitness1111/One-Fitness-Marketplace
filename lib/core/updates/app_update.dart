import "package:package_info_plus/package_info_plus.dart";

/// Whether this install should ask for an update.
enum UpdatePrompt { none, optional, blocking }

class AppUpdateConfig {
  const AppUpdateConfig({
    required this.minSupportedVersion,
    required this.latestVersion,
    required this.message,
    required this.forceUpdate,
    required this.appStoreUrl,
  });

  final String minSupportedVersion;
  final String latestVersion;
  final String message;
  final bool forceUpdate;
  final String appStoreUrl;

  static const fallbackMessage =
      "The ONE Fitness app has been updated with lots of new features. Update now.";

  static const placeholderUrl = "APP_STORE_LINK";

  factory AppUpdateConfig.fromJson(Map<String, dynamic> json) => AppUpdateConfig(
        minSupportedVersion: json["min_supported_version"]?.toString() ?? "0.0.0",
        latestVersion: json["latest_version"]?.toString() ?? "0.0.0",
        message: (json["update_message"]?.toString().trim().isNotEmpty ?? false)
            ? json["update_message"].toString()
            : fallbackMessage,
        forceUpdate: json["force_update"] == true,
        appStoreUrl: json["app_store_url"]?.toString() ?? "",
      );
}

/// Compares the number parts of two versions. "1.0.8+10" and "1.0.8" match.
int compareAppVersions(String a, String b) {
  final left = _parts(a);
  final right = _parts(b);
  for (var i = 0; i < 3; i++) {
    final diff = left[i] - right[i];
    if (diff != 0) return diff;
  }
  return 0;
}

UpdatePrompt updatePromptFor({
  required String installed,
  required AppUpdateConfig config,
}) {
  if (compareAppVersions(installed, config.minSupportedVersion) < 0) {
    return UpdatePrompt.blocking;
  }
  final behind = compareAppVersions(installed, config.latestVersion) < 0;
  if (!behind) return UpdatePrompt.none;
  if (config.forceUpdate) return UpdatePrompt.blocking;
  return UpdatePrompt.optional;
}

/// The version baked into this build. Falls back to the pubspec number when
/// the store metadata isn't available, which is the case in tests.
Future<String> installedAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.trim().isNotEmpty) return info.version.trim();
  } catch (_) {}
  return "1.0.8";
}

bool appStoreLinkReady(String url) {
  final text = url.trim();
  return text.isNotEmpty && text != AppUpdateConfig.placeholderUrl;
}

List<int> _parts(String version) {
  final core = version.split("+").first.split("-").first;
  final bits = core.split(".");
  return [
    for (var i = 0; i < 3; i++) i < bits.length ? int.tryParse(bits[i]) ?? 0 : 0,
  ];
}
