import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "../../../core/notifications/push_prompt.dart";
import "../../../core/chat/unread_chat.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/chat/chat_entry.dart";
import "../../../core/chat/owner_inbox.dart";
import "../../../core/widgets/owner_chat_list.dart";
import "../../../core/utils/chat_channels.dart";
import "../../../core/widgets/chat_gate.dart";
import "../../../core/widgets/message_reactions.dart";
import "../../../core/utils/coach_names.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/widgets/send_via_chips.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_info.dart";
import "../../../data/models/client_record.dart";
import "../../../data/models/comm_message.dart";
import "../../../data/providers/platform_settings_provider.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "broadcast_screen.dart";
import "team_chat_screen.dart";

/// Set from a client's quick action so Chat opens that thread.
class CoachChatOpenRequest extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String clientId) => state = clientId;

  void clear() {
    if (state != null) state = null;
  }
}

final coachChatOpenRequestProvider =
    NotifierProvider<CoachChatOpenRequest, String?>(CoachChatOpenRequest.new);

/// The three things the Chat tab can be showing.
enum _ChatView { list, thread, picker, broadcast }

const _prefRecipientKey = "coach_chat_client_id";
const _prefChannelKey = "coach_chat_channel";
const _prefChannelMarkerKey = "coach_chat_channel_default";

/// Mirrors the client-side chat_screen.dart's redesign, reversed: the coach
/// picks a client (searchable, from their scoped roster) instead of a
/// coach/business, then gets the same message-bubble conversation UI. Same
/// two-state shape: a one-time "who are you messaging" setup (remembered
/// per-device), then a normal chat thread with a slim context bar, a
/// pinned composer, and a "Change" flow to switch clients. Still a
/// timestamped log, not a live socket — every send is a real, persisted
/// client_records write.
class CoachChatScreen extends ConsumerStatefulWidget {
  const CoachChatScreen({super.key});

  @override
  ConsumerState<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends ConsumerState<CoachChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  bool _prefsLoaded = false;
  String? _recipientId;

  /// Which ways this coach's messages go out. Never empty — the picker
  /// won't allow it, so a thread always has somewhere to send.
  Set<ChatChannel> _channels = defaultChatChannels;

  /// Whether a client has been picked. The channels always have a value, so
  /// the recipient is the only thing that gates the picker.
  bool get _isSetUp => _recipientId != null;

  /// Which of the three views is showing. Chat opens on the recents list
  /// (like every messaging app), a thread is pushed on top of it, and the
  /// picker is only reached deliberately via "New message".
  _ChatView _view = _ChatView.list;
  final Set<String> _pendingIds = {};

  /// Owner list: which coach's threads are showing, and the open thread.
  String _ownerFilter = kOwnerFilterAll;
  String _ownerQuery = "";
  String? _ownerCoachKey;

  /// Coaches / owner / ONE Fitness Marketplace, and the staff messages
  /// involving this person, so teammates sit in the same list as clients.
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _staffMessages = [];
  RealtimeChannel? _staffChannel;

  /// Empty before sign-in, and in a widget test that never starts Supabase.
  /// The shell keeps this page mounted behind the one on screen, so a
  /// missing client must not take the other pages down with it.
  String get _me {
    try {
      return SupabaseService.currentUser?.id ?? "";
    } catch (_) {
      return "";
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadStaff();
    // The trainer shell builds this page even when another tab is showing.
    // A test, or a moment before sign-in finishes, has no live client yet.
    // The thread still opens; the live staff list starts once the client is up.
    try {
      _staffChannel = SupabaseService.client
          .channel("coach_chat_staff_live")
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: "public",
            table: "staff_messages",
            callback: (_) => _loadStaff(),
          )
          .subscribe();
    } catch (_) {
      _staffChannel = null;
    }
  }

  Future<void> _loadStaff() async {
    try {
      final people = await SupabaseService.loadStaffDirectory();
      final msgs = await SupabaseService.loadStaffMessages();
      if (mounted) {
        setState(() {
          _staff = people;
          _staffMessages = msgs;
        });
      }
    } catch (_) {}
  }

  bool get _iAmOwner => _staff.any((p) => p["id"] == _me && p["role"] == "owner");

  Set<String> _ownerIds() => {
        if (_me.isNotEmpty) _me,
        for (final person in _staff)
          if (person["role"] == "owner" && person["id"] is String) person["id"] as String,
      };

  String _coachLabel(String coachKey) {
    if (coachKey == kOwnerBusinessKey) return kOneFitnessLabel;
    final matches = ref.read(trainersProvider).where((t) => t.id == coachKey);
    if (matches.isEmpty) return coachPublicName();
    return matches.first.displayTitle;
  }

  /// Teammates other than me, plus the business contact.
  /// Chat history walks this full list, so a past direct thread with the
  /// owner still appears when it has messages.
  List<Map<String, dynamic>> get _teammates => [
        {"id": "market", "name": kMarketplaceName, "role": "market"},
        ...(_staff.where((p) => p["id"] != _me).toList()
          ..sort((a, b) => ((a["name"] as String?) ?? "").compareTo((b["name"] as String?) ?? ""))),
      ];

  /// "Who are you messaging?" — same people, minus the owner tile for a coach.
  List<Map<String, dynamic>> get _newChatTeammates =>
      staffNewChatChoices(_teammates, viewerIsOwner: _iAmOwner);

  List<ChatConversation> _staffConversations(Set<String> unreadKeys) {
    final out = <ChatConversation>[];
    for (final t in _teammates) {
      final key = t["id"] as String;
      final thread = staffThreadMessages(
        key: key,
        me: _me,
        viewerIsOwner: _iAmOwner,
        messages: _staffMessages,
      );
      if (thread.isEmpty) continue;
      final last = thread.last;
      out.add(ChatConversation(
        id: "staff:$key",
        name: staffLabel(t),
        preview: last["body"] as String? ?? "",
        at: DateTime.tryParse(last["created_at"]?.toString() ?? "")?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
        outgoing: last["sender_id"] == _me,
        unread: unreadKeys.contains("staff:$key"),
      ));
    }
    return out;
  }

  String _staffName(String? id) {
    for (final p in _staff) {
      if (p["id"] == id) return staffLabel(p);
    }
    return "Teammate";
  }

  /// Owner only: every coach <-> coach conversation, read-only. (RLS already
  /// hides these from coaches; this just lists them for the owner.)
  List<ChatConversation> _pairConversations() {
    if (!_iAmOwner) return const [];
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final m in _staffMessages) {
      final a = m["sender_id"] as String?;
      final b = m["recipient_id"] as String?;
      if (a == null || b == null || a == _me || b == _me) continue;
      final ids = [a, b]..sort();
      groups.putIfAbsent("${ids[0]}:${ids[1]}", () => []).add(m);
    }
    return [
      for (final e in groups.entries)
        ChatConversation(
          id: "pair:${e.key}",
          name: e.key.split(":").map(_staffName).join(" ↔ "),
          preview: e.value.last["body"] as String? ?? "",
          at: DateTime.tryParse(e.value.last["created_at"]?.toString() ?? "")?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
    ];
  }

  void _openPair(String pairKey) {
    final ids = pairKey.split(":");
    final msgs = _staffMessages
        .where((m) => ids.contains(m["sender_id"]) && ids.contains(m["recipient_id"]) && m["sender_id"] != m["recipient_id"])
        .toList();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.bg,
          title: Text(ids.map(_staffName).join(" ↔ "), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        ),
        body: msgs.isEmpty
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text("Read-only — you're viewing this as the owner.", style: TextStyle(fontSize: 11, color: AppColors.mute)),
                  ),
                  for (final m in msgs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_staffName(m["sender_id"] as String?), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.gold)),
                            const SizedBox(height: 3),
                            Text(m["body"] as String? ?? "", style: const TextStyle(fontSize: 14)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ));
  }

  void _openStaffChat(String key, Set<ChatChannel> channels) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: AppColors.bg,
            body: SafeArea(child: TeamChatScreen(initialKey: key, initialChannels: channels)),
          ),
        ))
        .then((_) {
          _loadStaff();
          ref.read(unreadChatKeysProvider.notifier).refresh();
        });
  }

  @override
  void dispose() {
    final sc = _staffChannel;
    if (sc != null) {
      try {
        SupabaseService.client.removeChannel(sc);
      } catch (_) {}
    }
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      if (mounted) setState(() => _prefsLoaded = true);
      return;
    }
    final savedRecipient = prefs.getString(_prefRecipientKey);
    // Values written by an older build come through the legacy spellings,
    // so a coach's remembered choice survives the update.
    final resolved = resolveSavedChatChannels(
      prefs.getString(_prefChannelKey),
      prefs.getString(_prefChannelMarkerKey),
    );
    if (resolved.writeBack) {
      await prefs.setString(_prefChannelKey, encodeChannels(resolved.channels));
      await prefs.setString(_prefChannelMarkerKey, chatChannelDefaultMarker);
    }
    if (!mounted) return;
    setState(() {
      _recipientId = savedRecipient;
      _channels = resolved.channels;
      _prefsLoaded = true;
    });
    if (_isSetUp) {
      _markThreadRead(_recipientId!);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animate: false));
    }
  }

  Future<void> _confirmSetup(String recipientId, Set<ChatChannel> channels) async {
    // A teammate (coach / owner / business) rather than a client.
    if (recipientId.startsWith("staff:")) {
      setState(() => _view = _ChatView.list);
      _openStaffChat(recipientId.substring(6), channels);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRecipientKey, recipientId);
    await prefs.setString(_prefChannelKey, encodeChannels(channels));
    await prefs.setString(_prefChannelMarkerKey, chatChannelDefaultMarker);
    if (!mounted) return;
    setState(() {
      _recipientId = recipientId;
      _channels = channels;
      // Without this the picker just re-rendered itself: confirming set the
      // recipient but left the view on `picker`, so "Start chat" looked
      // like it did nothing.
      _view = _ChatView.thread;
    });
    _markThreadRead(recipientId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// Marks a client's unread messages read the moment the coach actually
  /// views that thread — on first opening it and on every "Change" back
  /// into it (including a remembered thread reopened via SharedPreferences)
  /// — mirrors the old _CoachCompose.initState's read-receipt behavior.
  void _markThreadRead(String clientId) {
    SupabaseService.markChatRead(clientId);
    ref.read(unreadChatKeysProvider.notifier).clear(clientId);
    final trainerAuth = ref.read(trainerAuthProvider);
    final record = ref.read(trainerClientRecordsProvider)[clientId];
    if (record == null) return;
    // Same scope as the conversation list's bold/dot (and the thread itself):
    // the owner sees every coach's messages, so opening the thread has to mark
    // all of them read, not only the ones addressed to "owner".
    final isOwner = trainerAuth == "owner";
    bool isUnread(CommMessage m) =>
        m.who == "client" && !m.readByCoach && (isOwner || m.trainerId == null || m.trainerId == trainerAuth);
    if (!record.comms.any(isUnread)) return;
    final updated = record.comms.map((m) => isUnread(m) ? m.copyWith(readByCoach: true) : m).toList();
    ref.read(trainerClientRecordsProvider.notifier).update(clientId, (r) => r.copyWith(comms: updated));
    SupabaseService.markMessagesRead(clientId).catchError((Object _) {});
  }

  /// The owner opened one thread. Other threads with that client stay unread.
  void _markOwnerThreadRead(String clientId, String coachKey) {
    final key = ownerUnreadKey(clientId, coachKey);
    SupabaseService.markChatRead(key);
    ref.read(unreadChatKeysProvider.notifier).clear(key);
    final record = ref.read(trainerClientRecordsProvider)[clientId];
    if (record == null) return;
    final ownerIds = _ownerIds();
    bool unreadInThread(CommMessage m) =>
        ownerThreadCoachKey(m, ownerIds) == coachKey && m.who == "client" && !m.readByCoach;
    if (!record.comms.any(unreadInThread)) return;
    final ids = [for (final m in record.comms) if (unreadInThread(m)) m.id];
    final updated = record.comms.map((m) => unreadInThread(m) ? m.copyWith(readByCoach: true) : m).toList();
    ref.read(trainerClientRecordsProvider.notifier).update(clientId, (r) => r.copyWith(comms: updated));
    SupabaseService.markMessageIdsRead(ids).catchError((Object _) {});
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(target, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else {
      _scrollController.jumpTo(target);
    }
  }

  Future<void> _openChangeSheet(List<ClientInfo> roster) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _RecipientSetup(
          roster: roster,
          staff: _newChatTeammates,
          initialRecipientId: _recipientId,
          initialChannels: _channels,
          confirmLabel: "Save",
          onCancel: () => Navigator.of(ctx).pop(),
          onConfirm: (recipientId, channels) {
            Navigator.of(ctx).pop();
            _confirmSetup(recipientId, channels);
          },
        ),
      ),
    );
  }

  Future<void> _send({
    required ClientInfo client,
    required PlatformSettings settings,
    required Set<ChatChannel> channels,
    required String? trainerAuth,
  }) async {
    var deliver = channelsSavedOnTheMessage(channels);
    if (deliver.contains(ChatChannel.sms)) {
      final agreed = await ensureSmsConsent(context);
      if (!agreed) deliver = {...deliver}..remove(ChatChannel.sms);
    }
    if (deliver.isEmpty) deliver = {ChatChannel.inapp};
    final typed = _msgController.text.trim();
    if (typed.isEmpty) return;
    // Clients only ever see the coach name ("Coach Chris"), never the legal
    // name. An owner writing from the owner account goes out as the business.
    final isOwnerSend = trainerAuth == "owner";
    final sender = ref.read(trainersProvider).where((t) => t.id == trainerAuth);
    final from = isOwnerSend
        ? kMarketplaceName
        : (sender.isNotEmpty ? sender.first.displayTitle : kMarketplaceName);
    final replyCoach = _ownerCoachKey;
    final intoCoachThread = isOwnerSend && replyCoach != null && replyCoach != kOwnerBusinessKey;
    final text = prefixMessage(from, typed);
    // Optimistic bubble under a temporary id; the server returns the real
    // row, and is where the content filter and block rules are applied.
    final tempId = DateTime.now().microsecondsSinceEpoch.toString();
    final pending = CommMessage(
      id: tempId,
      who: "trainer",
      text: text,
      at: stamp(),
      trainerId: intoCoachThread ? replyCoach : (isOwnerSend ? null : trainerAuth),
      routedTo: isOwnerSend && !intoCoachThread ? kOwnerBusinessKey : null,
      readByCoach: true,
      channel: encodeChannels(deliver),
      createdAt: DateTime.now(),
    );
    _msgController.clear();
    setState(() => _pendingIds.add(tempId));
    ref.read(trainerClientRecordsProvider.notifier).update(client.id, (r) => r.copyWith(comms: [pending, ...r.comms]));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    try {
      final saved = await SupabaseService.sendMessage(
        clientId: client.id,
        trainerId: trainerAuth,
        who: "trainer",
        text: text,
        channel: encodeChannels(deliver),
        threadTrainerId: intoCoachThread ? replyCoach : null,
      );
      ref.read(trainerClientRecordsProvider.notifier).update(
            client.id,
            (r) => r.copyWith(comms: r.comms.map((c) => c.id == tempId ? saved : c).toList()),
          );
      // The push is what In app means in practice — the message is in the
      // thread either way. `sms: false` because SMS is a channel of its
      // own here; letting the push text them too would double-send to a
      // coach who picked both.
      if (deliver.contains(ChatChannel.inapp)) {
        notifyPush(profileId: client.id, title: "New message from $from", body: text);
      }
    } catch (e) {
      ref.read(trainerClientRecordsProvider.notifier).update(
            client.id,
            (r) => r.copyWith(comms: r.comms.where((c) => c.id != tempId).toList()),
          );
      if (mounted) {
        // Keep the text so it only needs rewording, and say why it bounced.
        _msgController.text = text;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("That message didn't send. Check your connection and try again."),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingIds.remove(tempId));
    }
    if (channels.contains(ChatChannel.email)) {
      SupabaseService.sendEmail(
        profileId: client.id,
        subject: "New message from $from — ${settings.businessName}",
        text: text,
      ).catchError((Object e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("The email didn't send. The message in the app is still there.")),
          );
        }
      });
    }
  }

  /// Clients this coach has actually exchanged messages with, newest first.
  /// Built from the same trainer-scoped filter the thread itself uses, so a
  /// coach never sees a conversation in the list they can't then open.
  List<ChatConversation> _recentConversations(
    List<ClientInfo> roster,
    Map<String, ClientRecord> records,
    String? trainerAuth,
    bool isOwner,
    Set<String> unreadKeys,
  ) {
    final out = <ChatConversation>[];
    for (final c in roster) {
      final comms = records[c.id]?.comms ?? const <CommMessage>[];
      final mine = comms.where((m) => isOwner || m.trainerId == null || m.trainerId == trainerAuth).toList();
      if (mine.isEmpty) continue;
      mine.sort((a, b) => b.sentAt.compareTo(a.sentAt));
      final last = mine.first;
      out.add(ChatConversation(
        id: c.id,
        name: c.name,
        photo: c.photo,
        preview: last.text,
        at: last.sentAt,
        outgoing: last.who == "trainer",
        // Unread means the client wrote something the coach hasn't opened
        // yet — the same flag the thread clears on open.
        unread: unreadKeys.contains(c.id) || mine.any((m) => m.who == "client" && !m.readByCoach),
      ));
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  List<OwnerInboxRow> _teamRows(Set<String> unreadKeys) {
    final rows = <OwnerInboxRow>[];
    for (final conversation in [..._staffConversations(unreadKeys), ..._pairConversations()]) {
      rows.add(OwnerInboxRow(
        id: conversation.id,
        clientId: null,
        coachKey: _teamCoachKey(conversation.id),
        title: conversation.name,
        coachLabel: kTeamChatLabel,
        preview: conversation.preview,
        at: conversation.at,
        unread: conversation.unread,
        outgoing: conversation.outgoing,
        team: true,
        participantIds: _teamParticipants(conversation.id),
      ));
    }
    return rows;
  }

  String _teamCoachKey(String id) {
    if (id == "staff:market") return kOwnerBusinessKey;
    if (id.startsWith("staff:")) return id.substring("staff:".length);
    return id;
  }

  Set<String> _teamParticipants(String id) {
    if (id == "staff:market") return const {};
    if (id.startsWith("staff:")) return {id.substring("staff:".length)};
    if (id.startsWith("pair:")) {
      final parts = id.substring("pair:".length).split(":");
      return parts.where((part) => part.isNotEmpty).toSet();
    }
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(coachChatOpenRequestProvider, (previous, next) {
      if (next == null) return;
      final owner = ref.read(trainerAuthProvider) == "owner";
      var coachKey = kOwnerBusinessKey;
      if (owner) {
        final comms = ref.read(trainerClientRecordsProvider)[next]?.comms ?? const <CommMessage>[];
        final ownerIds = _ownerIds();
        DateTime? latest;
        for (final message in comms) {
          if (latest != null && !message.sentAt.isAfter(latest)) continue;
          latest = message.sentAt;
          coachKey = ownerThreadCoachKey(message, ownerIds);
        }
      }
      setState(() {
        _recipientId = next;
        _ownerCoachKey = owner ? coachKey : null;
        _view = _ChatView.thread;
        _prefsLoaded = true;
      });
      if (owner) {
        _markOwnerThreadRead(next, coachKey);
      } else {
        _markThreadRead(next);
      }
      ref.read(coachChatOpenRequestProvider.notifier).clear();
    });
    return ChatEntryGate(child: _buildChat(context));
  }

  Widget _buildChat(BuildContext context) {
    if (!_prefsLoaded) {
      return Center(child: Text("Loading your chats…", style: TextStyle(fontSize: 14, color: AppColors.txt)));
    }

    final trainerAuth = ref.watch(trainerAuthProvider);
    final isOwner = trainerAuth == "owner";
    final roster = ref.watch(trainerRosterProvider);
    final records = ref.watch(trainerClientRecordsProvider);
    final unreadKeys = ref.watch(unreadChatKeysProvider);
    final settings = ref.watch(platformSettingsProvider);

    final selectedMatches = roster.where((c) => c.id == _recipientId);

    if (_view == _ChatView.picker || (_view == _ChatView.thread && (!_isSetUp || selectedMatches.isEmpty))) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _view = _ChatView.list),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _RecipientSetup(
            roster: roster,
            staff: _newChatTeammates,
            initialRecipientId: _recipientId,
            initialChannels: _channels,
            confirmLabel: "Start chat",
            onConfirm: _confirmSetup,
          ),
        ),
      );
    }

    if (_view == _ChatView.broadcast) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _view = _ChatView.list),
        child: const BroadcastScreen(),
      );
    }

    if (_view == _ChatView.list && isOwner) {
      final trainers = ref.watch(trainersProvider);
      final threads = ownerClientThreads(
        roster: roster,
        commsByClient: {for (final entry in records.entries) entry.key: entry.value.comms},
        coaches: trainers,
        ownerIds: _ownerIds(),
        unreadKeys: unreadKeys,
      );
      final team = _teamRows(unreadKeys);
      final visible = filterOwnerInbox(
        [...threads, ...team]..sort((a, b) => b.at.compareTo(a.at)),
        coachKey: _ownerFilter,
        query: _ownerQuery,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (settings.supportPhone.trim().isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(alignment: Alignment.centerLeft, child: CallGymButton()),
            ),
          Expanded(
            child: OwnerChatList(
              rows: visible,
              filters: ownerCoachFilters(trainers),
              selectedKey: _ownerFilter,
              query: _ownerQuery,
              onFilter: (key) => setState(() => _ownerFilter = key),
              onQuery: (value) => setState(() => _ownerQuery = value),
              emptyText: _ownerQuery.trim().isEmpty && _ownerFilter == kOwnerFilterAll
                  ? "No conversations yet. Start one with a client below — everything you send is timestamped and logged."
                  : "No conversations match.",
              onOpen: (id) {
                if (id.startsWith("pair:")) {
                  _openPair(id.substring(5));
                  return;
                }
                if (id.startsWith("staff:")) {
                  SupabaseService.markChatRead(id);
                  ref.read(unreadChatKeysProvider.notifier).clear(id);
                  _openStaffChat(id.substring(6), _channels);
                  return;
                }
                final parsed = parseOwnerThreadId(id);
                if (parsed == null) return;
                setState(() {
                  _recipientId = parsed.clientId;
                  _ownerCoachKey = parsed.coachKey;
                  _view = _ChatView.thread;
                });
                _markOwnerThreadRead(parsed.clientId, parsed.coachKey);
              },
              onNewChat: () => setState(() => _view = _ChatView.picker),
              onNewBroadcast: () => setState(() => _view = _ChatView.broadcast),
            ),
          ),
        ],
      );
    }

    if (_view == _ChatView.list) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (settings.supportPhone.trim().isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(alignment: Alignment.centerLeft, child: CallGymButton()),
            ),
          Expanded(
            child: ConversationList(
              conversations: [..._recentConversations(roster, records, trainerAuth, isOwner, unreadKeys), ..._staffConversations(unreadKeys), ..._pairConversations()]
                ..sort((a, b) => b.at.compareTo(a.at)),
              emptyText: "No conversations yet. Start one with a client below — everything you send is timestamped and logged.",
              onOpen: (clientId) {
                if (clientId.startsWith("pair:")) {
                  _openPair(clientId.substring(5));
                  return;
                }
                if (clientId.startsWith("staff:")) {
                  SupabaseService.markChatRead(clientId);
                  ref.read(unreadChatKeysProvider.notifier).clear(clientId);
                  _openStaffChat(clientId.substring(6), _channels);
                  return;
                }
                setState(() {
                  _recipientId = clientId;
                  // Whatever channels they last used carry over; only the
                  // picker changes them, so reopening a thread doesn't
                  // silently switch how a message goes out.
                  _view = _ChatView.thread;
                });
                _markThreadRead(clientId);
              },
              onNewChat: () => setState(() => _view = _ChatView.picker),
              onNewBroadcast: () => setState(() => _view = _ChatView.broadcast),
            ),
          ),
        ],
      );
    }

    final client = selectedMatches.first;
    final comms = records[client.id]?.comms ?? const <CommMessage>[];
    final ownerKey = _ownerCoachKey ?? kOwnerBusinessKey;
    final thread = isOwner
        ? messagesForOwnerThread(comms, coachKey: ownerKey, ownerIds: _ownerIds())
        : (comms.where((m) => m.trainerId == null || m.trainerId == trainerAuth).toList()
          ..sort((a, b) => a.sentAt.compareTo(b.sentAt)));

    return LocalBackScope(
      isOpen: true,
      onBack: () => setState(() => _view = _ChatView.list),
      child: Column(
      children: [
        _ContextBar(
          client: client,
          channelLabel: chatChannelsLabel(_channels),
          withLabel: isOwner ? "with ${_coachLabel(ownerKey)}" : null,
          onChange: () => _openChangeSheet(roster),
        ),
        Expanded(
          child: thread.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      "No messages yet — everything you send here is timestamped and logged.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: AppColors.mute, height: 1.5),
                    ),
                  ),
                )
              : ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: _buildBubbleList(thread, client.id),
                ),
        ),
        _Composer(
          controller: _msgController,
          recipientName: client.name,
          replyAs: isOwner ? kOwnerReplyLabel : null,
          onSend: () => _send(client: client, settings: settings, channels: _channels, trainerAuth: trainerAuth),
        ),
      ],
      ),
    );
  }

  Future<void> _react({
    required String clientId,
    required CommMessage message,
    required String reaction,
  }) async {
    final me = SupabaseService.currentUser?.id;
    if (me == null) return;
    final reactions = [
      ...message.reactions.where((r) => r.userId != me),
      MessageReaction(userId: me, reaction: reaction),
    ];
    ref.read(trainerClientRecordsProvider.notifier).update(
          clientId,
          (r) => r.copyWith(
            comms: r.comms.map((c) => c.id == message.id ? c.copyWith(reactions: reactions) : c).toList(),
          ),
        );
    try {
      await SupabaseService.setMessageReaction(
        messageId: message.id,
        clientId: clientId,
        reaction: reaction,
        routedTo: message.trainerId == null ? "business" : "conversation",
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That like didn't save. The message is still there.")),
      );
    }
  }

  List<Widget> _buildBubbleList(List<CommMessage> thread, String clientId) {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final c in thread) {
      final day = DateTime(c.sentAt.year, c.sentAt.month, c.sentAt.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DaySeparator(label: _dayLabel(day)));
        lastDay = day;
      }
      items.add(_Bubble(
        message: c,
        isPending: _pendingIds.contains(c.id),
        onReact: _pendingIds.contains(c.id)
            ? null
            : (reaction) => _react(clientId: clientId, message: c, reaction: reaction),
      ));
    }
    return items;
  }
}

String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  if (day == today) return "Today";
  if (day == yesterday) return "Yesterday";
  return niceDate(isoDate(day));
}

String _timeOnly(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? "AM" : "PM";
  return "$h:${d.minute.toString().padLeft(2, '0')} $ampm";
}

/// Roster size at or below which every client is listed up front. Above it,
/// the picker waits for a search query rather than rendering the whole gym.
const _browseAllMax = 8;

/// State 1 — "Who are you messaging?": search the coach's (scoped) roster
/// and pick a client, used both as the initial full-screen setup and
/// (pre-filled, with Cancel/Save) as the "Change" bottom sheet.
class _RecipientSetup extends StatefulWidget {
  const _RecipientSetup({
    required this.roster,
    this.staff = const [],
    required this.initialRecipientId,
    required this.initialChannels,
    required this.confirmLabel,
    required this.onConfirm,
    this.onCancel,
  });

  final List<ClientInfo> roster;

  /// Coaches / owner / the business, listed after the clients. Their ids come
  /// back prefixed "staff:".
  final List<Map<String, dynamic>> staff;
  final String? initialRecipientId;
  final Set<ChatChannel> initialChannels;
  final String confirmLabel;
  final void Function(String recipientId, Set<ChatChannel> channels) onConfirm;
  final VoidCallback? onCancel;

  @override
  State<_RecipientSetup> createState() => _RecipientSetupState();
}

class _RecipientSetupState extends State<_RecipientSetup> {
  late String? _recipientId = widget.initialRecipientId;
  late Set<ChatChannel> _channels =
      widget.initialChannels.isEmpty ? defaultChatChannels : widget.initialChannels;
  final _searchController = TextEditingController();
  String _query = "";

  ClientInfo? get _selected =>
      widget.roster.where((c) => c.id == _recipientId).firstOrNull;

  String? get _selectedName => _selected?.name;

  /// Only true once a client is actually picked — an unpicked recipient
  /// isn't a client without a number.
  bool get _selectedHasNoPhone {
    final client = _selected;
    final phone = client?.phone;
    // A missing value means this viewer is not allowed to see the number.
    // It does not mean the client has no phone.
    return client != null && phone != null && phone.trim().isEmpty;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The channels can't be emptied, so only the client gates Confirm.
    final canConfirm = _recipientId != null && canSendOn(_channels);
    final q = _query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    // A short roster is quicker to scan than to type into, so it stays
    // listed. Past that, listing everyone buries the search box under a
    // scroll of cards and makes the picker slower the more clients the gym
    // signs up — so the search does the work instead.
    final browseable = widget.roster.length <= _browseAllMax;
    final matches = searching
        ? widget.roster
            .where((c) => c.name.toLowerCase().contains(q) || (c.email ?? "").toLowerCase().contains(q))
            .toList()
        : widget.roster;
    // Whoever's already picked stays on screen even with the search empty —
    // this same widget is the "Change" sheet, and hiding the current
    // recipient there would lose the context of who you're switching from.
    final results = (searching || browseable)
        ? matches
        : widget.roster.where((c) => c.id == _recipientId).toList();
    final promptToSearch = !searching && !browseable;
    // Teammates are always listed (only a handful); search narrows them too.
    final teamMatches = widget.staff
        .where((t) => !searching || ((t["name"] as String?) ?? "").toLowerCase().contains(q))
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Who are you messaging?",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.txt),
          ),
          const SizedBox(height: 14),
          AppField(kind: FieldKind.search,
            controller: _searchController,
            placeholder: "Search clients and coaches…",
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 10),
          if (results.isEmpty && searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: HintBox(text: "No clients match your search.", bordered: false),
            )
          else
            ...results.map((c) {
              final selected = c.id == _recipientId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TapHighlight(
                  onTap: () => setState(() => _recipientId = c.id),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.gold.withValues(alpha: 0.1) : AppColors.card,
                      border: Border.all(color: selected ? AppColors.gold : AppColors.line),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Avatar(src: c.photo, name: c.name, size: 36),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                              Text(
                                c.email ?? "No email on file",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: AppColors.mute),
                              ),
                            ],
                          ),
                        ),
                        if (selected) Icon(LucideIcons.checkCircle2, size: 18, color: AppColors.gold),
                      ],
                    ),
                  ),
                ),
              );
            }),
          if (promptToSearch)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: HintBox(
                text: "Start typing a name or email to find one of your ${widget.roster.length} clients.",
                bordered: false,
              ),
            ),
          if (teamMatches.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text("Coaches & team", style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            const SizedBox(height: 8),
            for (final t in teamMatches)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TapHighlight(
                  onTap: () => setState(() => _recipientId = "staff:${t["id"]}"),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _recipientId == "staff:${t["id"]}" ? AppColors.gold.withValues(alpha: 0.1) : AppColors.card,
                      border: Border.all(color: _recipientId == "staff:${t["id"]}" ? AppColors.gold : AppColors.line),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          t["role"] == "market" ? LucideIcons.building2 : (t["role"] == "owner" ? LucideIcons.crown : LucideIcons.user),
                          size: 22,
                          color: AppColors.gold,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(staffLabel(t), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                              Text(
                                t["role"] == "market" ? "Business contact" : (t["role"] == "owner" ? "Owner" : "Coach"),
                                style: TextStyle(fontSize: 11, color: AppColors.mute),
                              ),
                            ],
                          ),
                        ),
                        if (_recipientId == "staff:${t["id"]}") Icon(LucideIcons.checkCircle2, size: 18, color: AppColors.gold),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          SendViaChips(
            channels: _channels,
            onChanged: (next) => setState(() => _channels = next),
          ),
          // Clients aren't asked for a number any more, so a coach picking
          // SMS needs to know up front when there's nothing to text —
          // rather than finding out from a snackbar after sending.
          if (_channels.contains(ChatChannel.sms) && _selectedHasNoPhone) ...[
            const SizedBox(height: 8),
            Text(
              "${_selectedName ?? "This client"} has no phone number on file — SMS will be skipped.",
              style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: BtnGold(
                  onPressed: canConfirm ? () => widget.onConfirm(_recipientId!, _channels) : null,
                  child: Text(widget.confirmLabel),
                ),
              ),
              if (widget.onCancel != null) ...[
                const SizedBox(width: 8),
                BtnGhost(onPressed: widget.onCancel, child: const Text("Cancel")),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// State 2's slim sticky header — who this thread is with, how, and a way
/// to change either without leaving the conversation.
class _ContextBar extends StatelessWidget {
  const _ContextBar({
    required this.client,
    required this.channelLabel,
    required this.onChange,
    this.withLabel,
  });
  final ClientInfo client;
  final String channelLabel;
  final VoidCallback onChange;
  final String? withLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Avatar(src: client.photo, name: client.name, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  client.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.txt),
                ),
                Text(
                  withLabel == null ? "via $channelLabel" : "$withLabel · via $channelLabel",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: AppColors.mute),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(foregroundColor: AppColors.gold, padding: EdgeInsets.zero, minimumSize: Size.zero),
            child: const Text("Change", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12)),
          child: Text(label, style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.isPending, this.onReact});
  final CommMessage message;
  final bool isPending;
  final void Function(String reaction)? onReact;

  @override
  Widget build(BuildContext context) {
    final isMine = message.who == "trainer";
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomLeft: Radius.circular(isMine ? 14 : 4),
      bottomRight: Radius.circular(isMine ? 4 : 14),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
            child: TapHighlight(
              onTap: onReact == null ? null : () => onReact!("heart"),
              onLongPress: () async {
                final action = await showMessageActions(context, canReport: false);
                if (!context.mounted || action == null) return;
                if (action == "heart" || action == "thumb") onReact?.call(action);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                decoration: BoxDecoration(
                  color: isMine ? AppColors.gold : AppColors.card,
                  border: isMine ? null : Border.all(color: AppColors.line),
                  borderRadius: radius,
                ),
                child: Text(
                  message.text,
                  style: TextStyle(color: isMine ? AppColors.onGold : AppColors.txt, fontSize: 14, height: 1.35),
                ),
              ),
            ),
          ),
          ReactionMarks(reactions: message.reactions),
          const SizedBox(height: 3),
          isPending
              ? Text("Sending…", style: TextStyle(fontSize: 10.5, color: AppColors.mute, fontStyle: FontStyle.italic))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_timeOnly(message.sentAt), style: TextStyle(fontSize: 10.5, color: AppColors.mute)),
                    if (message.channel != null) ...[
                      const SizedBox(width: 4),
                      _ChannelBadge(channel: message.channel!),
                    ],
                  ],
                ),
        ],
      ),
    );
  }
}

class _ChannelBadge extends StatelessWidget {
  const _ChannelBadge({required this.channel});

  /// As stored on the row: the comma-joined form, or one of the older
  /// single values — including the "sms" that sms-inbound writes for a
  /// client's texted reply. [decodeChannels] reads them all.
  final String channel;

  @override
  Widget build(BuildContext context) {
    final channels = decodeChannels(channel);
    final icons = <IconData>[
      if (channels.contains(ChatChannel.inapp)) LucideIcons.smartphone,
      if (channels.contains(ChatChannel.sms)) LucideIcons.messageSquare,
      if (channels.contains(ChatChannel.email)) LucideIcons.mail,
    ];
    if (icons.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final i in icons)
          Padding(padding: const EdgeInsets.only(left: 2), child: Icon(i, size: 9, color: AppColors.mute)),
      ],
    );
  }
}

/// Bottom composer, pinned above the tab bar — a single rounded input that
/// grows to 4 lines then scrolls, and a circular send button.
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.recipientName,
    required this.onSend,
    this.replyAs,
  });
  final TextEditingController controller;
  final String recipientName;
  final VoidCallback onSend;

  /// When set, the box says the reply is sent as this name.
  final String? replyAs;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyAs != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Replying as ${widget.replyAs}",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.gold),
                  ),
                ),
              ),
            const ChatSavedNotice(),
            const PushOffHint(),
            Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 110),
                child: TextField(
                  onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                  controller: widget.controller,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
                  minLines: 1,
                  maxLines: 4,
                  style: TextStyle(color: AppColors.txt, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: "Message ${widget.recipientName}…",
                    hintStyle: TextStyle(color: AppColors.mute, fontSize: 14),
                    filled: true,
                    fillColor: AppColors.card,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(color: AppColors.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(color: AppColors.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(color: AppColors.gold),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TapHighlight(
              onTap: hasText ? widget.onSend : null,
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hasText ? AppColors.gold : AppColors.card,
                  border: hasText ? null : Border.all(color: AppColors.line),
                ),
                child: Icon(LucideIcons.send, size: 17, color: hasText ? AppColors.onGold : AppColors.mute),
              ),
            ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}
