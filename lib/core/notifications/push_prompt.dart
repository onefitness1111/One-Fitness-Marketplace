import "package:firebase_messaging/firebase_messaging.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:app_settings/app_settings.dart";
import "../session/login_prompts.dart";
import "../theme/app_colors.dart";
import "push_service.dart";

const _snoozeKey = "push_banner_hide_until";

class PushNotice {
  const PushNotice({required this.known, required this.authorized, required this.snoozed});
  final bool known;
  final bool authorized;
  final bool snoozed;

  bool get showBanner => known && !authorized && !snoozed;
}

class PushNoticeNotifier extends Notifier<PushNotice> {
  @override
  PushNotice build() {
    Future.microtask(refresh);
    return const PushNotice(known: false, authorized: true, snoozed: false);
  }

  Future<void> refresh() async {
    if (kIsWeb) {
      state = const PushNotice(known: true, authorized: true, snoozed: false);
      return;
    }
    var authorized = false;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      authorized = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      authorized = false;
    }
    var snoozed = false;
    try {
      final raw = (await SharedPreferences.getInstance()).getInt(_snoozeKey);
      snoozed = raw != null && DateTime.now().millisecondsSinceEpoch < raw;
    } catch (_) {}
    state = PushNotice(known: true, authorized: authorized, snoozed: snoozed);
    if (authorized) {
      await PushService.registerForCurrentUser();
    }
  }

  Future<void> snooze() async {
    final until = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch;
    try {
      await (await SharedPreferences.getInstance()).setInt(_snoozeKey, until);
    } catch (_) {}
    state = PushNotice(known: state.known, authorized: state.authorized, snoozed: true);
  }

  /// Asks when the system has not decided yet. Opens this app's Settings
  /// page when the person already said no.
  Future<void> enable() async {
    if (kIsWeb) return;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
        await FirebaseMessaging.instance.requestPermission();
      } else if (settings.authorizationStatus == AuthorizationStatus.denied) {
        await AppSettings.openAppSettings();
      }
    } catch (_) {}
    await refresh();
  }
}

final pushNoticeProvider = NotifierProvider<PushNoticeNotifier, PushNotice>(PushNoticeNotifier.new);

class TurnOnNotificationsBanner extends ConsumerWidget {
  const TurnOnNotificationsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(pushNoticeProvider);
    if (!notice.showBanner) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.line),
        ),
        child: InkWell(
          onTap: gateLoginTap(() => ref.read(pushNoticeProvider.notifier).enable()),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    "Turn on notifications",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.txt),
                  ),
                ),
                IconButton(
                  onPressed: gateLoginTap(() => ref.read(pushNoticeProvider.notifier).snooze()),
                  icon: Icon(Icons.close, size: 18, color: AppColors.mute),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PushOffHint extends ConsumerWidget {
  const PushOffHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(pushNoticeProvider);
    if (!notice.known || notice.authorized) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: gateLoginTap(() => ref.read(pushNoticeProvider.notifier).enable()),
        child: Text(
          "Notifications are off. Tap to turn them on.",
          style: TextStyle(fontSize: 12, color: AppColors.mute),
        ),
      ),
    );
  }
}
