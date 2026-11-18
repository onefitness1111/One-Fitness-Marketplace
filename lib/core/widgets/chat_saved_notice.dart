import "package:flutter/material.dart";
import "../theme/app_colors.dart";

/// Short line under the message box. It used to be a faint gray sentence
/// that was hard to read on a phone. This stays one line, in the normal
/// text color, so it is obvious that the gym keeps the conversation.
class ChatSavedNotice extends StatelessWidget {
  const ChatSavedNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        "ONE Fitness can see this chat.",
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 1.3,
          color: AppColors.txt,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
