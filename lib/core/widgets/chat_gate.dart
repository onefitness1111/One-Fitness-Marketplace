import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../../data/providers/client_providers.dart";
import "../chat/chat_entry.dart";
import "../legal/sms_consent.dart";
import "../supabase/supabase_service.dart";
import "../theme/app_colors.dart";
import "../utils/phone_guard.dart";

const _introPrefKey = "chat_intro_ok_v1";

/// Blocks chat until the signed-in person has a phone number, then shows
/// the one-time explanation of @CoachName and the 6-hour window.
class ChatEntryGate extends ConsumerStatefulWidget {
  const ChatEntryGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ChatEntryGate> createState() => _ChatEntryGateState();
}

class _ChatEntryGateState extends ConsumerState<ChatEntryGate> {
  String? _phone;
  bool _ready = false;
  bool _introScheduled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? phone;
    try {
      phone = await SupabaseService.myPhone();
    } catch (_) {
      phone = null;
    }
    if (!mounted) return;
    String? me;
    try {
      me = SupabaseService.currentUser?.id;
    } catch (_) {
      me = null;
    }
    final info = ref.read(clientInfoProvider);
    if (me != null && info.id == me && phone != null) {
      ref.read(clientInfoProvider.notifier).update((i) => i.copyWith(phone: phone));
    }
    setState(() {
      _phone = phone;
      _ready = true;
    });
    if (chatMayOpen(phone: phone)) _scheduleIntro();
  }

  Future<void> _scheduleIntro() async {
    if (_introScheduled) return;
    _introScheduled = true;
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    if (prefs.getBool(_introPrefKey) == true) return;
    final seen = await SupabaseService.chatIntroSeen();
    if (seen) {
      await prefs.setBool(_introPrefKey, true);
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text(kChatIntroTitle, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: const Text(kChatIntroBody, style: TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(kChatIntroOk, style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    await prefs.setBool(_introPrefKey, true);
    await SupabaseService.markChatIntroSeen();
  }

  Future<void> _addPhone() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: const _OwnPhoneSheet(),
      ),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Center(child: Text("Loading your chats…", style: TextStyle(fontSize: 14, color: AppColors.txt)));
    }
    if (!chatMayOpen(phone: _phone)) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Add your phone number",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.txt),
            ),
            const SizedBox(height: 10),
            Text(
              "Chat needs a number on your profile. Texts from the business line use that number. You only enter it once.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.4, color: AppColors.mute),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _addPhone,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.txt,
                foregroundColor: AppColors.bg,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text("Add your phone number", style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );
    }
    return widget.child;
  }
}

class _OwnPhoneSheet extends StatefulWidget {
  const _OwnPhoneSheet();

  @override
  State<_OwnPhoneSheet> createState() => _OwnPhoneSheetState();
}

class _OwnPhoneSheetState extends State<_OwnPhoneSheet> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final phone = _controller.text.trim();
    if (!hasProfilePhone(phone)) {
      setState(() => _error = "Enter a number we can text.");
      return;
    }
    final gymErr = gymNumberError(context, phone);
    if (gymErr != null) {
      setState(() => _error = gymErr);
      return;
    }
    final id = SupabaseService.currentUser?.id;
    if (id == null) {
      setState(() => _error = "You're signed out. Sign in and try again.");
      return;
    }
    setState(() => _busy = true);
    try {
      await SupabaseService.updateClientRow(id, phone: phone);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst("Exception: ", "");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("Add your phone number", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.txt)),
          const SizedBox(height: 8),
          Text(
            "This is the number texts from the business line use. It is saved on your profile.",
            style: TextStyle(fontSize: 13, height: 1.4, color: AppColors.mute),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.phone,
            autofocus: true,
            style: TextStyle(color: AppColors.txt, fontSize: 15),
            decoration: InputDecoration(
              hintText: "(555) 010-0199",
              errorText: _error,
              filled: true,
              fillColor: AppColors.bg,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(backgroundColor: AppColors.txt, foregroundColor: AppColors.bg),
            child: Text(_busy ? "Saving…" : "Save number", style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

/// Asks for the existing SMS disclosure the first time this person will
/// text or be texted. Returns true once consent is on file.
Future<bool> ensureSmsConsent(BuildContext context) async {
  final id = SupabaseService.currentUser?.id;
  if (id == null) return false;
  if (await SupabaseService.hasSmsConsent(id)) return true;
  if (!context.mounted) return false;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text("Text messages", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: Text(
        "$kSmsConsentLabel\n\n$kSmsConsentDisclosure",
        style: const TextStyle(fontSize: 14, height: 1.4),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Not now")),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text("I agree", style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
  if (agreed == true) {
    await SupabaseService.recordSmsConsent(id);
    return true;
  }
  return false;
}
