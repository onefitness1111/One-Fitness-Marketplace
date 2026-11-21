import "package:flutter/material.dart";

import "../../../core/legal/sms_opt_in_prompt.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";

/// Owner only. Sends the in-app push. Nothing is sent when this card
/// is built — the owner has to tap the button.
class SmsOptInAskCard extends StatefulWidget {
  const SmsOptInAskCard({super.key, this.onSend});

  /// Test hook. The live card calls [SupabaseService.promptSmsOptIn].
  final Future<Map<String, dynamic>> Function()? onSend;

  @override
  State<SmsOptInAskCard> createState() => _SmsOptInAskCardState();
}

class _SmsOptInAskCardState extends State<SmsOptInAskCard> {
  bool _busy = false;
  String? _note;

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final send = widget.onSend ?? SupabaseService.promptSmsOptIn;
      final result = await send();
      final sent = result["sent"];
      final clients = result["clients"];
      if (!mounted) return;
      if (sent is num && clients is num) {
        setState(() => _note = "Notified $sent phones. $clients clients can open the prompt.");
      } else {
        setState(() => _note = "Sent.");
      }
    } catch (_) {
      if (mounted) setState(() => _note = "That prompt didn't send.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Text opt-in", style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 4),
          Text(
            "Sends an app notification — \"$kSmsOptInPushTitle\" — to clients who have not agreed to texts and have not opted out. It does not text them. Nothing is sent until you tap the button.",
            style: TextStyle(color: AppColors.mute, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          BtnGold(
            onPressed: _busy ? null : _send,
            child: Text(_busy ? "Sending…" : "Ask clients about texts"),
          ),
          if (_note != null) ...[
            const SizedBox(height: 8),
            Text(_note!, style: TextStyle(color: AppColors.txt, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}
