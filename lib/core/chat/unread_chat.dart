import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "../supabase/supabase_service.dart";

/// Thread list keys that still have a message this person has not opened.
/// Empty until the read-state migration is applied, and empty when they are
/// caught up. Realtime and app resume both call [UnreadChatKeys.refresh].
class UnreadChatKeys extends Notifier<Set<String>> {
  RealtimeChannel? _messages;
  RealtimeChannel? _staff;
  RealtimeChannel? _reads;
  var _listening = false;

  @override
  Set<String> build() {
    ref.onDispose(_stop);
    _listen();
    Future.microtask(refresh);
    return const {};
  }

  Future<void> refresh() async {
    try {
      final keys = await SupabaseService.loadUnreadChatKeys();
      if (!ref.mounted) return;
      state = keys;
    } catch (_) {}
  }

  void clear(String listKey) {
    if (!state.contains(listKey)) return;
    state = {...state}..remove(listKey);
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    try {
      final id = DateTime.now().microsecondsSinceEpoch;
      _messages = SupabaseService.client
          .channel("unread_messages_$id")
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: "public",
            table: "messages",
            callback: (_) => refresh(),
          )
          .subscribe();
      _staff = SupabaseService.client
          .channel("unread_staff_$id")
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: "public",
            table: "staff_messages",
            callback: (_) => refresh(),
          )
          .subscribe();
      _reads = SupabaseService.client
          .channel("unread_reads_$id")
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: "public",
            table: "thread_reads",
            callback: (_) => refresh(),
          )
          .subscribe();
    } catch (_) {
      _listening = false;
    }
  }

  void _stop() {
    _listening = false;
    for (final channel in [_messages, _staff, _reads]) {
      if (channel == null) continue;
      try {
        SupabaseService.client.removeChannel(channel);
      } catch (_) {}
    }
    _messages = null;
    _staff = null;
    _reads = null;
  }
}

final unreadChatKeysProvider = NotifierProvider<UnreadChatKeys, Set<String>>(UnreadChatKeys.new);
