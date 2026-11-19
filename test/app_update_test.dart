import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/updates/app_update.dart";

AppUpdateConfig config({
  String min = "1.0.0",
  String latest = "1.2.0",
  bool force = false,
  String url = "https://apps.apple.com/app/id000",
}) =>
    AppUpdateConfig(
      minSupportedVersion: min,
      latestVersion: latest,
      message: AppUpdateConfig.fallbackMessage,
      forceUpdate: force,
      appStoreUrl: url,
    );

void main() {
  test("a current install is left alone", () {
    expect(
      updatePromptFor(installed: "1.2.0", config: config()),
      UpdatePrompt.none,
    );
    expect(compareAppVersions("1.0.8+10", "1.0.8"), 0);
  });

  test("an older install gets a dismissible prompt, and a too-old one is blocked", () {
    expect(updatePromptFor(installed: "1.1.0", config: config()), UpdatePrompt.optional);
    expect(updatePromptFor(installed: "0.9.0", config: config()), UpdatePrompt.blocking);
    expect(
      updatePromptFor(installed: "1.1.0", config: config(force: true)),
      UpdatePrompt.blocking,
    );
  });

  test("the placeholder store link is not treated as a real address", () {
    expect(appStoreLinkReady(AppUpdateConfig.placeholderUrl), isFalse);
    expect(appStoreLinkReady("https://apps.apple.com/app/id1"), isTrue);
    final parsed = AppUpdateConfig.fromJson({
      "min_supported_version": "1.0.0",
      "latest_version": "1.0.8",
      "update_message": "",
      "force_update": false,
      "app_store_url": "APP_STORE_LINK",
    });
    expect(parsed.message, AppUpdateConfig.fallbackMessage);
    expect(parsed.appStoreUrl, "APP_STORE_LINK");
  });
}
