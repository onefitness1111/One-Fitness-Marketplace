import "package:flutter/material.dart";

import "../theme/app_colors.dart";

/// An automatic acknowledgement in a chat thread. Centered and labeled so
/// it does not look like the coach, the owner, or the client typed it.
class AutoReplyNote extends StatelessWidget {
  const AutoReplyNote({super.key, required this.text, required this.sentAt});

  final String text;
  final DateTime sentAt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
          child: Column(
            children: [
              Text(
                "Automatic reply",
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.mute,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 4),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.35),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(_timeOnly(sentAt), style: TextStyle(fontSize: 10.5, color: AppColors.mute)),
            ],
          ),
        ),
      ),
    );
  }
}

String _timeOnly(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? "AM" : "PM";
  return "$h:${d.minute.toString().padLeft(2, '0')} $ampm";
}
