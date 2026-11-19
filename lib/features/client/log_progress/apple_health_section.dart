import "package:flutter/material.dart";
import "../../../core/health/apple_health.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/app_buttons.dart";
import "../../../core/widgets/app_card.dart";

/// Asks in plain language, then the iPhone permission sheet, then shows
/// today's steps, the latest heart rate, and the latest weight.
class AppleHealthSection extends StatefulWidget {
  const AppleHealthSection({super.key});

  @override
  State<AppleHealthSection> createState() => _AppleHealthSectionState();
}

class _AppleHealthSectionState extends State<AppleHealthSection> {
  AppleHealthReading? _reading;
  bool _busy = false;
  String? _note;

  Future<void> _connect() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Connect Apple Health?"),
        content: const Text(
          "ONE Fitness can read your steps, heart rate, and weight from Apple Health so they sit with the rest of your progress. "
          "It only reads those three. It does not write anything back, and it does not share them with other clients. "
          "You can turn this off later in the iPhone Settings app, under Health.",
          style: TextStyle(fontSize: 14, height: 1.35),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Not now")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Continue")),
        ],
      ),
    );
    if (agreed != true) return;
    setState(() { _busy = true; _note = null; });
    try {
      final ok = await AppleHealth.requestRead();
      if (!ok) {
        if (mounted) {
          setState(() => _note = "Apple Health access wasn't allowed. You can turn it on in Settings → Health → Data Access.");
        }
        return;
      }
      final reading = await AppleHealth.read();
      if (mounted) {
        setState(() {
          _reading = reading;
          _note = reading.hasAny ? null : "Connected. Nothing new from the last week yet.";
        });
      }
    } catch (_) {
      if (mounted) setState(() => _note = "Couldn't read Apple Health. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppleHealth.supported) return const SizedBox.shrink();
    final reading = _reading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Apple Health", style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              "Steps, heart rate, and weight from your iPhone. Read only.",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
            if (reading != null && reading.hasAny) ...[
              const SizedBox(height: 10),
              if (reading.stepsToday != null) Text("Steps today: ${reading.stepsToday}"),
              if (reading.heartRate != null) Text("Heart rate: ${reading.heartRate} bpm"),
              if (reading.weightLb != null) Text("Weight: ${reading.weightLb!.toStringAsFixed(1)} lb"),
            ],
            if (_note != null) ...[
              const SizedBox(height: 8),
              Text(_note!, style: TextStyle(fontSize: 12, color: AppColors.mute)),
            ],
            const SizedBox(height: 8),
            BtnGhost(
              onPressed: _busy ? null : _connect,
              full: true,
              child: Text(_busy ? "Asking…" : reading == null ? "Connect Apple Health" : "Refresh"),
            ),
          ],
        ),
      ),
    );
  }
}
