import "package:flutter/material.dart";

/// Green is the one exception Coach Chris asked for. Everything else stays
/// on the dark, gray, and white palette.
const unreadDotGreen = Color(0xFF22C55E);

class ChatLine {
  const ChatLine({
    required this.threadKey,
    required this.senderId,
    required this.at,
  });

  final String threadKey;
  final String senderId;
  final DateTime at;
}

class ThreadRead {
  const ThreadRead({required this.userId, required this.threadKey, required this.lastReadAt});

  final String userId;
  final String threadKey;
  final DateTime lastReadAt;
}

/// One person's read mark. Nobody else is allowed to see it.
bool readStateVisibleTo({required String markUserId, required String viewerId}) => markUserId == viewerId;

/// A message the viewer did not send, newer than the last time they opened
/// that thread. No read mark at all means it is still unread.
bool messageIsUnread({
  required String viewerId,
  required String senderId,
  required DateTime at,
  required DateTime? lastReadAt,
}) {
  if (senderId == viewerId) return false;
  if (lastReadAt == null) return true;
  return at.isAfter(lastReadAt);
}

Set<String> unreadThreadKeys({
  required String viewerId,
  required Iterable<ChatLine> messages,
  required Iterable<ThreadRead> reads,
}) {
  final mine = <String, DateTime>{
    for (final read in reads)
      if (read.userId == viewerId) read.threadKey: read.lastReadAt,
  };
  final unread = <String>{};
  for (final message in messages) {
    if (messageIsUnread(
      viewerId: viewerId,
      senderId: message.senderId,
      at: message.at,
      lastReadAt: mine[message.threadKey],
    )) {
      unread.add(message.threadKey);
    }
  }
  return unread;
}

bool showsChatDot(Set<String> unreadKeys) => unreadKeys.isNotEmpty;

/// Client and coach threads. Business chat (no coach, or the owner) is its
/// own key so it does not hide inside a coach thread.
String clientThreadKey({
  required String clientId,
  String? trainerId,
  bool trainerIsOwner = false,
}) {
  if (trainerId == null || trainerId.isEmpty || trainerIsOwner) return "business:$clientId";
  return "pair:$clientId:$trainerId";
}

String staffThreadKey({required String senderId, String? recipientId}) {
  if (recipientId == null || recipientId.isEmpty) return "staff:market";
  final ids = [senderId, recipientId]..sort();
  return "staff:${ids[0]}:${ids[1]}";
}

/// The id the chat list already uses for that thread.
String chatListKey({
  required String threadKey,
  required String viewerId,
  required bool viewerIsClient,
}) {
  if (threadKey.startsWith("business:")) {
    return viewerIsClient ? "business" : threadKey.substring("business:".length);
  }
  if (threadKey.startsWith("pair:")) {
    final parts = threadKey.split(":");
    if (parts.length >= 3) {
      final clientId = parts[1];
      final trainerId = parts.sublist(2).join(":");
      return viewerId == clientId ? trainerId : clientId;
    }
  }
  if (threadKey == "staff:market") return "staff:market";
  if (threadKey.startsWith("staff:")) {
    final ids = threadKey.substring("staff:".length).split(":");
    if (ids.length == 2) {
      return "staff:${ids[0] == viewerId ? ids[1] : ids[0]}";
    }
  }
  return threadKey;
}

/// Opening a thread moves last-read to now, which clears that dot.
ThreadRead markThreadRead({
  required String userId,
  required String threadKey,
  required DateTime at,
}) =>
    ThreadRead(userId: userId, threadKey: threadKey, lastReadAt: at);
