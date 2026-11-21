import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/chat_channels.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/widgets/widgets.dart";

/// Team Chat: coaches message each other and the business contact
/// (ONE Fitness Marketplace). Marketplace messages reach the owner and go
/// by In app or Email only, never SMS. A coach does not get a separate
/// owner person in this list. The owner still messages coaches directly.
/// Staff talking to each other may see a legal name when no coach name is set.
/// A client never uses this. Client screens use [coachPublicName] only.
String staffLabel(Map<String, dynamic>? p) {
  if (p?["role"] == "coach") {
    final chosen = ((p?["coach_name"] as String?) ?? "").trim();
    if (chosen.isNotEmpty) return chosen;
    final legal = ((p?["name"] as String?) ?? "").trim();
    if (legal.isNotEmpty) return legal;
    return "Coach";
  }
  final name = ((p?["name"] as String?) ?? "").trim();
  if (name.isEmpty) return "Teammate";
  return name;
}

/// People offered when starting a new staff chat.
///
/// A coach keeps the business contact and other coaches. They do not get a
/// separate tile for an owner profile (`role == "owner"`). That person is
/// reached through ONE Fitness Marketplace (`id` "market", no recipient).
/// The owner still sees every other owner and every coach.
///
/// This list is only the new-chat picker. A direct thread that already
/// exists with the owner stays in chat history and can still be opened.
List<Map<String, dynamic>> staffNewChatChoices(
  Iterable<Map<String, dynamic>> people, {
  required bool viewerIsOwner,
}) {
  return [
    for (final p in people)
      if (viewerIsOwner || p["role"] != "owner") p,
  ];
}

/// Messages already in one staff thread, in the order they were loaded.
///
/// "market" is the business contact (`recipient_id` null). Any other id is
/// the direct thread with that profile. A past direct thread with the owner
/// stays on the owner's id. Those rows are not copied onto Marketplace.
List<Map<String, dynamic>> staffThreadMessages({
  required String key,
  required String me,
  required bool viewerIsOwner,
  required Iterable<Map<String, dynamic>> messages,
}) {
  if (key == "market") {
    return messages.where((m) => m["recipient_id"] == null && (viewerIsOwner || m["sender_id"] == me)).toList();
  }
  return messages
      .where((m) => (m["sender_id"] == me && m["recipient_id"] == key) || (m["sender_id"] == key && m["recipient_id"] == me))
      .toList();
}

class TeamChatScreen extends StatefulWidget {
  const TeamChatScreen({super.key, this.initialKey, this.initialChannels});

  /// When set ("market" or a profile id) the screen opens straight into that
  /// conversation, and back leaves the screen instead of showing a list.
  final String? initialKey;
  final Set<ChatChannel>? initialChannels;

  @override
  State<TeamChatScreen> createState() => _TeamChatScreenState();
}

class _TeamChatScreenState extends State<TeamChatScreen> {
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;

  /// null = the list; "market" = the business; otherwise a profile id.
  String? _open;

  /// Person highlighted in the setup list, before "Start chat".
  String? _pick;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  Set<ChatChannel> _channels = {...defaultChatChannels};
  bool _sending = false;

  String get _me => SupabaseService.currentUser?.id ?? "";

  void _markRead(String key) {
    SupabaseService.markChatRead(key == "market" ? "staff:market" : "staff:$key");
  }

  void _close() {
    if (widget.initialKey != null) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _open = null);
    }
  }

  @override
  void initState() {
    super.initState();
    _open = widget.initialKey;
    final initial = widget.initialKey;
    if (initial != null) _markRead(initial);
    final ch = widget.initialChannels;
    if (ch != null && ch.isNotEmpty) _channels = {...ch, ChatChannel.inapp};
    _load();
    try {
      _channel = SupabaseService.client
          .channel("staff_messages_live")
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: "public",
            table: "staff_messages",
            callback: (_) => _load(quiet: true),
          )
          .subscribe();
    } catch (_) {
      _channel = null;
    }
  }

  @override
  void dispose() {
    final c = _channel;
    if (c != null) {
      try {
        SupabaseService.client.removeChannel(c);
      } catch (_) {}
    }
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final people = await SupabaseService.loadStaffDirectory();
      final messages = await SupabaseService.loadStaffMessages();
      if (!mounted) return;
      setState(() {
        _people = people;
        _messages = messages;
        _error = null;
      });
      _toBottom();
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = "Couldn't load Team Chat — check your connection.");
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });

  Map<String, dynamic>? _person(String id) {
    for (final p in _people) {
      if (p["id"] == id) return p;
    }
    return null;
  }

  bool get _iAmOwner => _person(_me)?["role"] == "owner";

  List<Map<String, dynamic>> _thread(String key) => staffThreadMessages(
        key: key,
        me: _me,
        viewerIsOwner: _iAmOwner,
        messages: _messages,
      );

  Future<void> _send() async {
    final key = _open;
    final body = _text.text.trim();
    if (key == null || body.isEmpty || _sending) return;
    final toMarket = key == "market";
    // SMS is never available for the business contact.
    final chosen = {..._channels, ChatChannel.inapp};
    if (toMarket) chosen.remove(ChatChannel.sms);
    setState(() => _sending = true);
    try {
      await SupabaseService.sendStaffMessage(
        recipientId: toMarket ? null : key,
        body: body,
        channel: encodeChannels(chosen),
      );
      _text.clear();
      final myName = (_person(_me)?["name"] as String?) ?? "A teammate";
      final targets = toMarket
          ? _people.where((p) => p["role"] == "owner" && p["id"] != _me).toList()
          : [
              if (_person(key) != null) _person(key)!,
            ];
      for (final t in targets) {
        notifyPush(profileId: t["id"] as String, title: "Message from $myName", body: body);
        if (chosen.contains(ChatChannel.email)) {
          SupabaseService.sendEmail(
            profileId: t["id"] as String,
            subject: "Message from $myName — ONE Fitness",
            text: body,
          ).catchError((Object e) {});
        }
        if (!toMarket && chosen.contains(ChatChannel.sms)) {
          SupabaseService.sendSms(profileId: t["id"] as String, text: "$myName: $body").catchError((Object e) {});
        }
      }
      await _load(quiet: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst("Exception: ", ""))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String? _lastBody(String key) {
    final t = _thread(key);
    return t.isEmpty ? null : (t.last["body"] as String?);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: CircularProgressIndicator(color: AppColors.gold));
    final key = _open;
    if (key == null) return _list();
    return LocalBackScope(isOpen: true, onBack: _close, child: _threadView(key));
  }

  Widget _tile(String key, String title, String subtitle, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AppCard(
          onTap: () => setState(() => _pick = key),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.gold),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: AppColors.mute)),
                  ],
                ),
              ),
              if (_pick == key) Icon(LucideIcons.checkCircle2, size: 18, color: AppColors.gold),
            ],
          ),
        ),
      );

  Widget _list() {
    final others = staffNewChatChoices(
      _people.where((p) => p["id"] != _me),
      viewerIsOwner: _iAmOwner,
    ).toList()
      ..sort((a, b) => ((a["name"] as String?) ?? "").compareTo((b["name"] as String?) ?? ""));
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const SectionLabel("Who are you messaging?"),
        if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: HintBox(text: _error!)),
        _tile("market", kMarketplaceName, _lastBody("market") ?? "Business contact — in app or email", LucideIcons.building2),
        for (final p in others)
          _tile(
            p["id"] as String,
            staffLabel(p),
            _lastBody(p["id"] as String) ?? (p["role"] == "owner" ? "Owner" : "Coach"),
            p["role"] == "owner" ? LucideIcons.crown : LucideIcons.user,
          ),
        const SizedBox(height: 8),
        const SectionLabel("Kind of message"),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final ch in chatChannelOrder)
              if (_pick != "market" || ch != ChatChannel.sms)
                FilterChip(
                  label: Text(chatChannelLabels[ch]!, style: const TextStyle(fontSize: 12)),
                  selected: ch == ChatChannel.inapp || _channels.contains(ch),
                  onSelected: ch == ChatChannel.inapp
                      ? null
                      : (on) => setState(() => _channels = on ? {..._channels, ch} : ({..._channels}..remove(ch))),
                ),
          ],
        ),
        if (_pick == "market")
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text("SMS isn't available for $kMarketplaceName.", style: TextStyle(fontSize: 11, color: AppColors.mute)),
          ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _pick == null
              ? null
              : () {
                    final key = _pick!;
                    _markRead(key);
                    setState(() {
                      _open = key;
                      _toBottom();
                    });
                  },
          child: const Text("Start chat"),
        ),
      ],
    );
  }

  Widget _threadView(String key) {
    final toMarket = key == "market";
    final name = toMarket ? kMarketplaceName : staffLabel(_person(key));
    final msgs = _thread(key);
    final available = toMarket ? [ChatChannel.inapp, ChatChannel.email] : chatChannelOrder;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 18, 4),
          child: Row(
            children: [
              IconButton(onPressed: _close, icon: const Icon(LucideIcons.chevronLeft, size: 20)),
              Expanded(child: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
            ],
          ),
        ),
        Expanded(
          child: msgs.isEmpty
              ? Center(child: Text("No messages yet — say hello.", style: TextStyle(color: AppColors.mute, fontSize: 13)))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final mine = m["sender_id"] == _me;
                    final senderName = staffLabel(_person(m["sender_id"] as String));
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                        decoration: BoxDecoration(
                          color: mine ? AppColors.gold : AppColors.card,
                          borderRadius: BorderRadius.circular(12),
                          border: mine ? null : Border.all(color: AppColors.line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!mine && toMarket)
                              Text(senderName, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.mute)),
                            Text(m["body"] as String? ?? "", style: TextStyle(fontSize: 14, color: mine ? AppColors.onGold : AppColors.txt)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.line))),
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ChatSavedNotice(),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ch in chatChannelOrder)
                      if (available.contains(ch))
                        FilterChip(
                          label: Text(chatChannelLabels[ch]!, style: const TextStyle(fontSize: 12)),
                          selected: ch == ChatChannel.inapp || _channels.contains(ch),
                          // In app is always on — it is the thread itself.
                          onSelected: ch == ChatChannel.inapp
                              ? null
                              : (on) => setState(() => _channels = on ? {..._channels, ch} : ({..._channels}..remove(ch))),
                        ),
                  ],
                ),
                if (toMarket)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text("SMS isn't available for $kMarketplaceName.", style: TextStyle(fontSize: 11, color: AppColors.mute)),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                        controller: _text,
                        minLines: 1,
                        maxLines: 4,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(hintText: "Message $name…", isDense: true, border: const OutlineInputBorder()),
                      ),
                    ),
                    IconButton(onPressed: _sending ? null : _send, icon: Icon(LucideIcons.send, color: AppColors.gold)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
