import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../../../core/legal/sms_consent.dart";
import "../../../core/legal/sms_opt_in_prompt.dart";
import "../../../core/legal/terms_screen.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/client_providers.dart";

class SmsOptInPromptGate {
  const SmsOptInPromptGate({
    this.ready = false,
    this.optedOut = false,
    this.hiddenUntil,
  });

  final bool ready;
  final bool optedOut;
  final DateTime? hiddenUntil;
}

class SmsOptInPromptNotifier extends Notifier<SmsOptInPromptGate> {
  @override
  SmsOptInPromptGate build() {
    Future.microtask(refresh);
    return const SmsOptInPromptGate();
  }

  Future<void> refresh() async {
    DateTime? hidden;
    try {
      final raw = (await SharedPreferences.getInstance()).getInt(kSmsOptInHideUntilKey);
      if (raw != null) hidden = DateTime.fromMillisecondsSinceEpoch(raw);
    } catch (_) {}
    var optedOut = false;
    try {
      optedOut = await SupabaseService.mySmsOptedOut();
    } catch (_) {}
    state = SmsOptInPromptGate(ready: true, optedOut: optedOut, hiddenUntil: hidden);
  }

  Future<void> snooze() async {
    final until = smsOptInHiddenUntil(DateTime.now());
    try {
      await (await SharedPreferences.getInstance()).setInt(kSmsOptInHideUntilKey, until.millisecondsSinceEpoch);
    } catch (_) {}
    state = SmsOptInPromptGate(ready: true, optedOut: state.optedOut, hiddenUntil: until);
  }
}

final smsOptInPromptProvider = NotifierProvider<SmsOptInPromptNotifier, SmsOptInPromptGate>(
  SmsOptInPromptNotifier.new,
);

/// The card at the bottom of the dashboard, and the same card just above
/// the chat composer. [child] keeps a screen filling the space above it.
class SmsOptInPromptSlot extends ConsumerWidget {
  const SmsOptInPromptSlot({super.key, this.child, this.padding = EdgeInsets.zero});

  final Widget? child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(clientInfoProvider);
    final gate = ref.watch(smsOptInPromptProvider);
    final show = gate.ready &&
        showSmsOptInPrompt(
          smsOptIn: info.smsOptIn,
          smsOptedOut: gate.optedOut,
          hiddenUntil: gate.hiddenUntil,
          now: DateTime.now(),
        );
    final card = show
        ? Padding(
            padding: padding,
            child: SmsOptInPromptCard(
              onYes: () => acceptSmsTexts(context, ref),
              onNotNow: () => ref.read(smsOptInPromptProvider.notifier).snooze(),
            ),
          )
        : null;
    if (child == null) return card ?? const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (card != null) card,
        Expanded(child: child!),
      ],
    );
  }
}

class SmsOptInPromptCard extends StatelessWidget {
  const SmsOptInPromptCard({
    super.key,
    required this.onYes,
    required this.onNotNow,
    this.busy = false,
    this.fontFamily,
  });

  final VoidCallback? onYes;
  final VoidCallback? onNotNow;
  final bool busy;

  /// Set by screenshot tests so button labels use a real font. The app
  /// leaves this null and uses the same face as every other button.
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.zero,
      child: SmsOptInPromptBody(onYes: onYes, onNotNow: onNotNow, busy: busy, fontFamily: fontFamily),
    );
  }
}

class SmsOptInPromptBody extends StatelessWidget {
  const SmsOptInPromptBody({
    super.key,
    required this.onYes,
    required this.onNotNow,
    this.busy = false,
    this.fontFamily,
  });

  final VoidCallback? onYes;
  final VoidCallback? onNotNow;
  final bool busy;
  final String? fontFamily;

  TextStyle? get _buttonFace => fontFamily == null ? null : TextStyle(fontFamily: fontFamily);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kSmsOptInPromptTitle,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.txt, height: 1.25),
        ),
        const SizedBox(height: 8),
        Text(
          kSmsConsentLabel,
          style: TextStyle(fontSize: 13.5, height: 1.4, color: AppColors.txt),
        ),
        const SizedBox(height: 6),
        Text(
          kSmsConsentDisclosure,
          style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.mute),
        ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (ctx) => TermsScreen(onBack: () => Navigator.of(ctx).pop()),
              )),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.gold,
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text("Terms of Use", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
            ),
            Text("·", style: TextStyle(fontSize: 11, color: AppColors.mute)),
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (ctx) => PrivacyPolicyScreen(onBack: () => Navigator.of(ctx).pop()),
              )),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.gold,
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text("Privacy Policy", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        BtnGold(
          full: true,
          onPressed: busy ? null : onYes,
          child: Text(busy ? "Saving…" : kSmsOptInPromptYes, style: _buttonFace),
        ),
        const SizedBox(height: 8),
        BtnGhost(
          full: true,
          onPressed: busy ? null : onNotNow,
          child: Text(kSmsOptInPromptLater, style: _buttonFace),
        ),
      ],
    );
  }
}

Future<void> showSmsOptInPromptSheet(BuildContext context, WidgetRef ref) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + MediaQuery.of(ctx).viewPadding.bottom),
      child: SmsOptInPromptBody(
        onYes: () => Navigator.of(ctx).pop(true),
        onNotNow: () => Navigator.of(ctx).pop(false),
      ),
    ),
  );
  if (!context.mounted) return;
  if (accepted == true) {
    await acceptSmsTexts(context, ref);
  } else {
    await ref.read(smsOptInPromptProvider.notifier).snooze();
  }
}

Future<void> acceptSmsTexts(BuildContext context, WidgetRef ref) async {
  final id = ref.read(clientInfoProvider).id;
  final signedIn = SupabaseService.currentUser?.id ?? id;
  if (signedIn.isEmpty) return;
  final saved = await SupabaseService.recordSmsConsent(signedIn);
  if (!context.mounted) return;
  if (!saved) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Couldn't save that. Check your connection and try again.")),
    );
    return;
  }
  ref.read(clientInfoProvider.notifier).update((c) => c.copyWith(smsOptIn: true));
}
