import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../core/live_log/live_log_sync.dart";
import "../../core/theme/app_colors.dart";

/// "Live" / "Offline" strip for the shared session log.
class LiveSyncBanner extends StatelessWidget {
  const LiveSyncBanner({super.key, required this.otherParty});

  /// "your coach" or "your client" — who is on the other end of the log.
  final String otherParty;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: LiveLogOutbox.pending,
      builder: (_, pending, _) {
        final waiting = pending > 0;
        final color = waiting ? AppColors.danger : AppColors.grn;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            border: Border.all(color: color.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(waiting ? LucideIcons.cloudOff : LucideIcons.radio, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  waiting
                      ? "Saved on this phone — $pending change${pending == 1 ? "" : "s"} will sync when you're back online."
                      : "Live — shared with $otherParty. Changes appear instantly.",
                  style: TextStyle(fontSize: 11.5, color: AppColors.txt),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Notes for one exercise, shared by everyone on the log. Each note is its own
/// entry (who wrote it, when), so two people writing at once both land.
class LiveNotesBox extends StatefulWidget {
  const LiveNotesBox({super.key, required this.controller, required this.exercise});

  final LiveLogController controller;
  final String exercise;

  @override
  State<LiveNotesBox> createState() => _LiveNotesBoxState();
}

class _LiveNotesBoxState extends State<LiveNotesBox> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    widget.controller.addNote(widget.exercise, t);
    _text.clear();
  }

  String _label(LiveNote n) {
    final role = n.authorRole == "client" ? "" : " (${n.authorRole == "owner" ? "Admin" : "Coach"})";
    final name = n.authorName.isEmpty ? (n.authorRole == "client" ? "Client" : "Coach") : n.authorName;
    return "$name$role";
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ValueListenableBuilder<int>(
      valueListenable: c.notesTick,
      builder: (_, _, _) {
        final mine = c.notes.where((n) => n.exercise == widget.exercise).toList();
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("NOTES", style: TextStyle(fontSize: 9.5, color: AppColors.mute, fontWeight: FontWeight.w800, letterSpacing: 1)),
              for (final n in mine)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: "${_label(n)}: ", style: const TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(text: n.body),
                      ],
                    ),
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                      controller: _text,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(hintText: "Add a note…", isDense: true),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(onPressed: _send, icon: Icon(LucideIcons.send, size: 18, color: AppColors.gold)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
