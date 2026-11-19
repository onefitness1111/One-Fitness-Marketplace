import "package:flutter/material.dart";
import "unread_threads.dart";

/// The small green dot on Chat and on a conversation that still has unread
/// messages. Green is intentional.
class UnreadDot extends StatelessWidget {
  const UnreadDot({super.key, this.size = 8});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: unreadDotGreen, shape: BoxShape.circle),
    );
  }
}
