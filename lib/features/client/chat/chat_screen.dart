import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:shared_preferences/shared_preferences.dart";
import "../../../core/chat/client_recipients.dart";
import "../../../core/chat/unread_chat.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/notifications/push_prompt.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/report_block_sheet.dart";
import "../drawer_screens/add_phone_screen.dart";
import "../../../core/chat/chat_entry.dart";
import "../../../core/utils/chat_channels.dart";
import "../../../core/widgets/chat_gate.dart";
import "../../../core/widgets/send_via_chips.dart";
import "../../../core/widgets/message_reactions.dart";
import "../../../core/utils/coach_names.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_info.dart";
import "../../../data/models/client_record.dart";
import "../../../data/models/comm_message.dart";
import "../../../data/models/trainer.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/platform_settings_provider.dart";

/// The three things the Chat tab can be showing.
enum _ChatView { list, thread, picker }

const _prefRecipientKey = "chat_recipient_id";
const _prefChannelKey = "chat_channel";

/// Mirrors Comms.jsx (who: "client") — a timestamped communication log,
/// restyled to read as a real chat: a one-time "who are you messaging"
/// setup (remembered per-device), then a normal message-bubble thread with
/// a slim context bar and a pinned composer. Still a log, not a live
/// socket — every send is a real, timestamped, persisted client_records
/// write, same as before.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  bool _prefsLoaded = false;
  String? _recipientId; // coach id or "business"

  /// Never empty once a thread is open — the picker won't let it be, and a
  /// remembered value that decodes to nothing falls back to the default.
  Set<ChatChannel> _channels = defaultChatChannels;

  /// Whether a recipient has been chosen. The channels are never unset (a
  /// new chat starts on In app), so only the recipient gates the picker.
  bool get _isSetUp => _recipientId != null;

  /// Chat opens on the recents list; a thread sits on top of it, and the
  /// picker is only reached deliberately via "New message".
  _ChatView _view = _ChatView.list;
  final Set<String> _pendingIds = {};

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
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
    // A value saved by an older build decodes through the legacy spellings
    // — "inappSms" becomes In app + SMS, so nobody's remembered choice
    // changes under them. Anything unreadable falls back to the default
    // rather than leaving the thread with nothing selected.
    final saved = decodeChannels(prefs.getString(_prefChannelKey));
    if (!mounted) return;
    setState(() {
      _recipientId = savedRecipient;
      _channels = saved.isEmpty ? defaultChatChannels : saved;
      _prefsLoaded = true;
    });
    if (_isSetUp && _view == _ChatView.thread && _recipientId != null) {
      _markOpen(_recipientId!);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animate: false));
    }
  }

  void _markOpen(String recipientId) {
    SupabaseService.markChatRead(recipientId);
    ref.read(unreadChatKeysProvider.notifier).clear(recipientId);
  }

  Future<void> _confirmSetup(String recipientId, Set<ChatChannel> channels) async {
    final chosen = channels;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRecipientKey, recipientId);
    await prefs.setString(_prefChannelKey, encodeChannels(chosen));
    if (!mounted) return;
    setState(() {
      _recipientId = recipientId;
      _channels = chosen;
      _view = _ChatView.thread;
    });
    _markOpen(recipientId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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

  Future<void> _openChangeSheet({
    required List<Trainer> realCandidates,
    required String businessName,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _RecipientSetup(
          realCandidates: realCandidates,
          businessName: businessName,
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
    required Trainer selectedCoach,
    required ClientInfo info,
  }) async {
    final emailToo = _channels.contains(ChatChannel.email);
    var channels = channelsSavedOnTheMessage(_channels);
    if (selectedCoach.id == "business") channels = {...channels}..remove(ChatChannel.sms);
    if (channels.contains(ChatChannel.sms)) {
      final agreed = await ensureSmsConsent(context);
      if (!agreed) channels = {...channels}..remove(ChatChannel.sms);
    }
    if (channels.isEmpty) channels = {ChatChannel.inapp};
    final typed = _msgController.text.trim();
    if (typed.isEmpty) return;
    final text = prefixMessage(info.name.trim().isEmpty ? "Client" : info.name.trim(), typed);
    // Optimistic bubble, with a temporary local id. The real row — and its
    // real id — comes back from the server, which is also where the content
    // filter and the block rules are applied.
    final tempId = DateTime.now().microsecondsSinceEpoch.toString();
    final pending = CommMessage(
      id: tempId,
      who: "client",
      text: text,
      at: stamp(),
      trainerId: selectedCoach.id,
      channel: encodeChannels(channels),
      createdAt: DateTime.now(),
    );
    _msgController.clear();
    setState(() => _pendingIds.add(tempId));
    ref.read(clientRecordProvider.notifier).update((r) => r.copyWith(comms: [pending, ...r.comms]));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    var savedOk = false;
    try {
      final saved = await SupabaseService.sendMessage(
        clientId: info.id,
        trainerId: selectedCoach.id,
        who: "client",
        text: text,
        channel: encodeChannels(channels),
      );
      // Swap the placeholder for the stored row.
      ref.read(clientRecordProvider.notifier).update(
            (r) => r.copyWith(
              comms: r.comms.map((c) => c.id == tempId ? saved : c).toList(),
            ),
          );
      savedOk = true;
    } catch (e) {
      // Rejected (or offline): take the bubble back so the client never
      // sees an unsent message sitting there as though it went through.
      ref.read(clientRecordProvider.notifier).update(
            (r) => r.copyWith(comms: r.comms.where((c) => c.id != tempId).toList()),
          );
      if (mounted) {
        // Put the text back in the box so it isn't lost — they only need
        // to reword it.
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
    if (!savedOk) return;
    // In app: the message is in the thread either way, so what this adds
    // is the push. Without it an in-app-only message would sit unseen
    // until the coach happened to open the tab, which is what made the
    // old "In App" option feel like it did nothing.
    //
    // "business" is the picker's pseudo-coach for messaging the gym itself,
    // not a profile id — there's no single device to push to, and the
    // message is in the thread for whoever reads it. (sendMessage already
    // drops the same sentinel rather than writing it as a trainer_id.)
    // SMS is saved on the message. The database trigger texts the coach
    // from the business number. Email is not saved on the thread; it is
    // sent on its own, from ONE Fitness, to the coach's address.
    if (selectedCoach.id != "business") {
      SupabaseService.clientNotify("chat-to-staff", {
        "profileId": selectedCoach.id,
        "body": text,
      });
    }
    if (emailToo) {
      final profileId = selectedCoach.id == "business" ? _ownerProfileId() : selectedCoach.id;
      if (profileId != null) {
        final business = ref.read(platformSettingsProvider).businessName;
        SupabaseService.sendEmail(
          profileId: profileId,
          subject: "New message from ${info.name.trim().isEmpty ? "a client" : info.name.trim()} — $business",
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
  }

  String? _ownerProfileId() {
    final owners = ref.read(ownerDirectoryProvider);
    if (owners.isEmpty) return null;
    return owners.first.id;
  }

  /// Coaches this client has actually exchanged messages with, newest
  /// first. Messages with no trainerId are legacy/business-wide ones, which
  /// belong to whichever coach the thread view would show them under.
  List<ChatConversation> _recentConversations(ClientRecord client, List<Trainer> candidates, Set<String> unreadKeys) {
    final byCoach = <String, List<CommMessage>>{};
    for (final m in client.comms) {
      final key = m.trainerId == null || m.trainerId!.isEmpty ? "business" : m.trainerId!;
      byCoach.putIfAbsent(key, () => []).add(m);
    }
    final out = <ChatConversation>[];
    byCoach.forEach((coachId, msgs) {
      final coach = candidates.where((t) => t.id == coachId).firstOrNull;
      if (coach == null) return;
      msgs.sort((a, b) => b.sentAt.compareTo(a.sentAt));
      final last = msgs.first;
      out.add(ChatConversation(
        id: coach.id,
        name: coach.displayTitle,
        photo: coach.photo,
        preview: last.text,
        at: last.sentAt,
        outgoing: last.who == "client",
        unread: unreadKeys.contains(coach.id),
      ));
    });
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return ChatEntryGate(child: _buildChat(context));
  }

  Widget _buildChat(BuildContext context) {
    if (!_prefsLoaded) {
      return Center(child: Text("Loading your chats…", style: TextStyle(fontSize: 14, color: AppColors.txt)));
    }

    final info = ref.watch(clientInfoProvider);
    final client = ref.watch(clientRecordProvider);
    final trainers = ref.watch(trainersProvider);
    final settings = ref.watch(platformSettingsProvider);
    final owners = ref.watch(ownerDirectoryProvider);
    final scoped = trainers;
    final reach = clientRecipients(
      coachIds: scoped.map((t) => t.id),
      ownerIds: owners.map((o) => o.id).toSet(),
      messageTrainerIds: client.comms.map((m) => m.trainerId),
    );
    final realCandidates = [
      for (final t in scoped)
        if (reach.pickerCoachIds.contains(t.id)) t,
    ];
    final pastOwners = [
      for (final owner in owners)
        if (reach.historyIds.contains(owner.id) && realCandidates.every((t) => t.id != owner.id))
          Trainer(
            id: owner.id,
            name: owner.name,
            coachName: owner.name.isEmpty ? null : owner.name,
          ),
    ];
    final candidates = [
      ...realCandidates,
      ...pastOwners,
      Trainer(id: "business", name: kMarketplaceName),
    ];

    if (_view == _ChatView.picker || (_view == _ChatView.thread && !_isSetUp)) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _view = _ChatView.list),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _RecipientSetup(
            realCandidates: realCandidates,
            businessName: settings.businessName,
            initialRecipientId: _recipientId,
            initialChannels: _channels,
            confirmLabel: "Start chat",
            onConfirm: _confirmSetup,
          ),
        ),
      );
    }

    if (_view == _ChatView.list) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rather than message and wait, a client can just call the gym.
          if (settings.supportPhone.trim().isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(alignment: Alignment.centerLeft, child: CallGymButton()),
            ),
          Expanded(
            child: ConversationList(
              conversations: _recentConversations(client, candidates, ref.watch(unreadChatKeysProvider)),
              emptyText: "No conversations yet. Message your coach below — they'll see it right away.",
              newChatLabel: "New message",
              onOpen: (coachId) {
                setState(() {
                  _recipientId = coachId;
                  _view = _ChatView.thread;
                });
                _markOpen(coachId);
              },
              onNewChat: () => setState(() => _view = _ChatView.picker),
            ),
          ),
        ],
      );
    }

    final selectedCoach = candidates.firstWhere(
      (t) => t.id == _recipientId,
      orElse: () => candidates.first,
    );
    final thread = client.comms
        .where((c) => c.trainerId == null || c.trainerId == selectedCoach.id)
        .toList()
      ..sort((a, b) => a.sentAt.compareTo(b.sentAt));

    return LocalBackScope(
      isOpen: true,
      onBack: () => setState(() => _view = _ChatView.list),
      child: Column(
      children: [
        _ContextBar(
          coach: selectedCoach,
          channelLabel: chatChannelsLabel(_channels),
          onChange: () => _openChangeSheet(realCandidates: realCandidates, businessName: settings.businessName),
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
                  children: _buildBubbleList(thread, selectedCoach, info.id),
                ),
        ),
        _Composer(
          controller: _msgController,
          recipientName: selectedCoach.displayTitle,
          onSend: () => _send(selectedCoach: selectedCoach, info: info),
        ),
      ],
      ),
    );
  }

  Future<void> _react({
    required String infoId,
    required CommMessage message,
    required String reaction,
  }) async {
    final me = SupabaseService.currentUser?.id;
    if (me == null) return;
    final next = MessageReaction(userId: me, reaction: reaction);
    final reactions = [
      ...message.reactions.where((r) => r.userId != me),
      next,
    ];
    ref.read(clientRecordProvider.notifier).update(
          (r) => r.copyWith(
            comms: r.comms.map((c) => c.id == message.id ? c.copyWith(reactions: reactions) : c).toList(),
          ),
        );
    try {
      await SupabaseService.setMessageReaction(
        messageId: message.id,
        clientId: infoId,
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

  List<Widget> _buildBubbleList(List<CommMessage> thread, Trainer coach, String infoId) {
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
            : (reaction) => _react(infoId: infoId, message: c, reaction: reaction),
        // Only the coach's own messages can be reported — reporting your
        // own is meaningless, and a pending message has no stored id yet.
        onReport: (c.who == "client" || _pendingIds.contains(c.id))
            ? null
            : () => showReportBlockSheet(
                  context,
                  ref: ref,
                  reportedUserId: coach.id,
                  reportedUserName: coach.displayTitle,
                  contentType: "message",
                  contentId: c.id,
                  excerpt: c.text,
                ),
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

/// Shown from the ⓘ icon in ClientShell's top bar (chat screen only) —
/// keeps the "record you control" explanation available without a
/// permanent card taking up the top of the thread.
void showChatInfoSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.info, size: 16, color: AppColors.gold),
              const SizedBox(width: 8),
              Text(
                "About this chat",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.txt),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: Icon(LucideIcons.x, size: 18, color: AppColors.mute),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            "Every message is logged below, timestamped — a record you control.\n\n"
            "Pick any combination of the three ways to send. In app notifies them in ONE Fitness. "
            "SMS also texts them, and is the only one that needs a phone number. Email also emails "
            "them. In app on its own is fine — you never have to give a number to use the chat.",
            style: TextStyle(fontSize: 13, color: AppColors.mute, height: 1.5),
          ),
        ],
      ),
    ),
  );
}

/// SMS is not a channel for the business contact. In app stays on if it
/// was the only other choice, so the set is never empty.
Set<ChatChannel> withoutBusinessSms(Set<ChatChannel> channels) {
  if (!channels.contains(ChatChannel.sms)) return channels;
  final next = {...channels}..remove(ChatChannel.sms);
  return next.isEmpty ? {ChatChannel.inapp} : next;
}

/// In app, SMS, and Email for a client. The same row is the new-message
/// screen and the in-thread Change sheet.
class ClientSendViaSection extends StatelessWidget {
  const ClientSendViaSection({
    super.key,
    required this.channels,
    required this.onChanged,
    required this.businessSelected,
    required this.needsPhone,
    this.onAddPhone,
  });

  final Set<ChatChannel> channels;
  final ValueChanged<Set<ChatChannel>> onChanged;
  final bool businessSelected;
  final bool needsPhone;
  final VoidCallback? onAddPhone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SendViaChips(
          channels: channels,
          hidden: businessSelected ? const {ChatChannel.sms} : const {},
          onChanged: onChanged,
        ),
        if (businessSelected) ...[
          const SizedBox(height: 8),
          Text(
            "Texts aren't available for $kMarketplaceName.",
            style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
          ),
        ],
        if (needsPhone) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onAddPhone,
            child: Text(
              "Add a phone number in Profile Settings to get texts",
              style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4, decoration: TextDecoration.underline),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          "In app alerts your coach. Texts and emails are sent by ONE Fitness, not from your personal number or email.",
          style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
        ),
      ],
    );
  }
}

/// State 1 — "Who are you messaging?", used both as the initial full-screen
/// setup and (pre-filled, with Cancel/Save) as the "Change" bottom sheet.
class _RecipientSetup extends ConsumerStatefulWidget {
  const _RecipientSetup({
    required this.realCandidates,
    required this.businessName,
    required this.initialRecipientId,
    required this.initialChannels,
    required this.confirmLabel,
    required this.onConfirm,
    this.onCancel,
  });

  final List<Trainer> realCandidates;
  final String businessName;
  final String? initialRecipientId;
  final Set<ChatChannel> initialChannels;

  final String confirmLabel;
  final void Function(String recipientId, Set<ChatChannel> channels) onConfirm;
  final VoidCallback? onCancel;

  @override
  ConsumerState<_RecipientSetup> createState() => _RecipientSetupState();
}

class _RecipientSetupState extends ConsumerState<_RecipientSetup> {
  late String? _recipientId = widget.initialRecipientId;
  late Set<ChatChannel> _channels =
      widget.initialChannels.isEmpty ? defaultChatChannels : widget.initialChannels;

  Set<ChatChannel> get _shownChannels =>
      _recipientId == "business" ? withoutBusinessSms(_channels) : _channels;

  void _openAddPhone() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AddPhoneScreen(
        reason: "Add a phone number so ONE Fitness can text you.",
        onBack: () => Navigator.of(context).pop(),
        onSaved: () => Navigator.of(context).pop(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // The channels can't be emptied, so only the recipient gates Confirm.
    final canConfirm = _recipientId != null && canSendOn(_channels);

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
          if (widget.realCandidates.isNotEmpty) ...[
            _coachCard(),
            const SizedBox(height: 10),
          ],
          _businessCard(),
          const SizedBox(height: 20),
          ClientSendViaSection(
            channels: _shownChannels,
            businessSelected: _recipientId == "business",
            needsPhone: (ref.watch(clientInfoProvider).phone ?? "").trim().isEmpty,
            onChanged: (next) => setState(() => _channels = _recipientId == "business" ? withoutBusinessSms(next) : next),
            onAddPhone: _openAddPhone,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: BtnGold(
                  onPressed: canConfirm ? () => widget.onConfirm(_recipientId!, _shownChannels) : null,
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

  Widget _coachCard() {
    final validId = _recipientId != null && widget.realCandidates.any((t) => t.id == _recipientId);
    final current = validId ? widget.realCandidates.firstWhere((t) => t.id == _recipientId) : widget.realCandidates.first;
    return _SelectableCard(
      selected: validId,
      onTap: () => setState(() => _recipientId = current.id),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Your coach", style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                if (widget.realCandidates.length > 1)
                  TapHighlight(
                    onTap: () async {
                      final picked = await showModalBottomSheet<Trainer>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: AppColors.card,
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                        builder: (_) => _CoachSearchSheet(candidates: widget.realCandidates, selectedId: current.id),
                      );
                      if (picked != null) setState(() => _recipientId = picked.id);
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            current.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.txt),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(LucideIcons.search, size: 15, color: AppColors.mute),
                      ],
                    ),
                  )
                else
                  Text(current.displayTitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.txt)),
                const SizedBox(height: 3),
                Text("Training, form checks, plan questions", style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4)),
              ],
            ),
          ),
          if (validId) Padding(padding: EdgeInsets.only(left: 8), child: Icon(LucideIcons.checkCircle2, size: 20, color: AppColors.gold)),
        ],
      ),
    );
  }

  Widget _businessCard() {
    final selected = _recipientId == "business";
    return _SelectableCard(
      selected: selected,
      onTap: () => setState(() {
        _recipientId = "business";
        _channels = withoutBusinessSms(_channels);
      }),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(kMarketplaceName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.txt)),
                const SizedBox(height: 3),
                Text(
                  "Billing, emergencies, or anything that can't wait for your coach",
                  style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4),
                ),
              ],
            ),
          ),
          if (selected) Padding(padding: EdgeInsets.only(left: 8), child: Icon(LucideIcons.checkCircle2, size: 20, color: AppColors.gold)),
        ],
      ),
    );
  }
}

class _SelectableCard extends StatelessWidget {
  const _SelectableCard({required this.selected, required this.onTap, required this.child});
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TapHighlight(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? AppColors.gold.withValues(alpha: 0.1) : AppColors.card,
          border: Border.all(color: selected ? AppColors.gold : AppColors.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      ),
    );
  }
}

/// Bottom sheet for finding a specific coach by name, discipline, or
/// location — opened from `_coachCard()` whenever there's more than one
/// candidate coach to choose between. Mirrors squad_member_search_screen
/// .dart's search-field-over-a-filtered-list pattern; pops the picked
/// Trainer back to the caller, or null if dismissed without a pick.
class _CoachSearchSheet extends StatefulWidget {
  const _CoachSearchSheet({required this.candidates, required this.selectedId});
  final List<Trainer> candidates;
  final String selectedId;

  @override
  State<_CoachSearchSheet> createState() => _CoachSearchSheetState();
}

class _CoachSearchSheetState extends State<_CoachSearchSheet> {
  final _controller = TextEditingController();
  String _query = "";

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final results = q.isEmpty
        ? widget.candidates
        : widget.candidates.where((t) {
            final nameMatch = t.displayTitle.toLowerCase().contains(q);
            final discMatch = t.disciplines.any((d) => disciplineLabel(d).toLowerCase().contains(q));
            final locMatch = (t.locationName ?? "").toLowerCase().contains(q);
            return nameMatch || discMatch || locMatch;
          }).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionLabel("Find a coach"),
                  const SizedBox(height: 8),
                  AppField(kind: FieldKind.search,
                    controller: _controller,
                    placeholder: "Search by name, discipline, or location…",
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: results.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: HintBox(text: "No coaches match your search."),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final t = results[i];
                        final selected = t.id == widget.selectedId;
                        return AppCard(
                          borderColor: selected ? AppColors.gold : null,
                          onTap: () => Navigator.of(context).pop(t),
                          child: Row(
                            children: [
                              Avatar(src: t.photo, name: t.displayTitle, size: 40),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t.displayTitle, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                    if (t.disciplines.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          t.disciplines.map(disciplineLabel).join(", "),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 11, color: AppColors.mute),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (selected) Icon(LucideIcons.checkCircle2, size: 18, color: AppColors.gold),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// State 2's slim sticky header — who this thread is with, how, and a way
/// to change either without leaving the conversation.
class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.coach, required this.channelLabel, required this.onChange});
  final Trainer coach;
  final String channelLabel;
  final VoidCallback onChange;

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
          Avatar(src: coach.photo, name: coach.displayTitle, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  coach.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.txt),
                ),
                Text("via $channelLabel", style: TextStyle(fontSize: 11, color: AppColors.mute)),
              ],
            ),
          ),
          // Some things are quicker said out loud — one tap dials the gym.
          const CallGymButton(compact: true),
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
  const _Bubble({
    required this.message,
    required this.isPending,
    this.onReport,
    this.onReact,
  });
  final CommMessage message;
  final bool isPending;

  /// Long-press to report or block — offered on every message the client
  /// didn't write themselves (Apple guideline 1.2).
  final VoidCallback? onReport;
  final void Function(String reaction)? onReact;

  @override
  Widget build(BuildContext context) {
    final isMine = message.who == "client";
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
          if (!isMine && (message.groupName ?? "").isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 2),
              child: Text(
                message.groupName!,
                style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w600),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
            child: TapHighlight(
              onTap: onReact == null ? null : () => onReact!("heart"),
              onLongPress: () async {
                final action = await showMessageActions(context, canReport: onReport != null);
                if (!context.mounted || action == null) return;
                if (action == "heart" || action == "thumb") onReact?.call(action);
                if (action == "report") onReport?.call();
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

  /// As stored on the row — the comma-joined form, or one of the older
  /// single values. [decodeChannels] handles both, which is also what fixed
  /// the old badge: it compared against "inapp" while the enum wrote
  /// "inappSms", so texted messages carried no icon at all.
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
  const _Composer({required this.controller, required this.recipientName, required this.onSend});
  final TextEditingController controller;
  final String recipientName;
  final VoidCallback onSend;

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
