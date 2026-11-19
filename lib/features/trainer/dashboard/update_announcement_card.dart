import "package:flutter/material.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/updates/app_update.dart";
import "../../../core/widgets/widgets.dart";

/// A draft the owner can send once, by tapping Send. It does not go out
/// when the screen opens.
class UpdateAnnouncementCard extends StatefulWidget {
  const UpdateAnnouncementCard({super.key});

  @override
  State<UpdateAnnouncementCard> createState() => _UpdateAnnouncementCardState();
}

class _UpdateAnnouncementCardState extends State<UpdateAnnouncementCard> {
  final _text = TextEditingController(text: AppUpdateConfig.fallbackMessage);
  bool _busy = false;
  String? _note;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final result = await SupabaseService.announceAppUpdate(text: text);
      final sent = result["sent"];
      if (mounted) setState(() => _note = sent is num ? "Sent to $sent phones." : "Sent.");
    } catch (_) {
      if (mounted) setState(() => _note = "That announcement didn't send.");
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
          Text("Update announcement", style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 4),
          Text(
            "Draft only. Nothing is sent until you tap Send.",
            style: TextStyle(color: AppColors.mute, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          AppField(controller: _text, kind: FieldKind.text, minLines: 3, maxLines: 5),
          const SizedBox(height: 10),
          BtnGold(
            onPressed: _busy ? null : _send,
            child: Text(_busy ? "Sending…" : "Send update notice"),
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
