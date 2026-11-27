import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/broadcast.dart";
import "../../../core/utils/chat_channels.dart";
import "../../../core/utils/coach_names.dart";
import "../../../core/widgets/send_via_chips.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/client_info.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/coach_permissions_provider.dart";
import "../../../data/providers/trainer_providers.dart";

/// One message to many clients. Each app copy goes into that client's own
/// thread with the sender. A coach only sees their own clients.
class BroadcastScreen extends ConsumerStatefulWidget {
  const BroadcastScreen({super.key});

  @override
  ConsumerState<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ConsumerState<BroadcastScreen> {
  final _search = TextEditingController();
  final _groupName = TextEditingController();
  final _message = TextEditingController();
  final _subject = TextEditingController();
  bool _all = true;
  final Set<String> _picked = {};
  Set<ChatChannel> _channels = {ChatChannel.inapp};
  bool _reviewing = false;
  bool _sending = false;
  String? _error;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _search.dispose();
    _groupName.dispose();
    _message.dispose();
    _subject.dispose();
    super.dispose();
  }

  List<ClientInfo> _mine(List<ClientInfo> roster, bool isOwner, String? senderId) {
    if (isOwner || (senderId ?? "").trim().isNotEmpty) return roster;
    return const [];
  }

  List<BroadcastClient> _asPeople(List<ClientInfo> clients, bool isOwner) => [
        for (final c in clients)
          BroadcastClient(
            id: c.id,
            phone: isOwner ? (c.phone ?? "") : "",
            email: c.email ?? "",
            smsOptIn: c.smsOptIn,
          ),
      ];

  BroadcastScope _scope(List<ClientInfo> mine, bool isOwner, String senderId) {
    return scopeBroadcast(
      senderIsOwner: isOwner,
      senderId: senderId,
      all: _all,
      requestedIds: _picked.toList(),
      clients: _asPeople(mine, isOwner),
    );
  }

  BroadcastWays get _ways => broadcastWaysFromSet(_channels.map((c) => c.name).toSet());

  Future<void> _send(BroadcastScope scope) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final ways = _ways;
    final groupName = sanitizeGroupName(_groupName.text);
    try {
      final result = await SupabaseService.sendBroadcast(
        text: _message.text.trim(),
        channel: broadcastSummaryChannel(ways),
        channels: ways.wire,
        allClients: _all,
        clientIds: scope.allowed.map((c) => c.id).toList(),
        subject: ways.email ? _subject.text.trim() : null,
        groupName: groupName,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = "That broadcast didn't send. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trainerAuth = ref.watch(trainerAuthProvider);
    final isOwner = trainerAuth == "owner";
    final senderId = isOwner ? (SupabaseService.currentUser?.id ?? "") : (trainerAuth ?? "");
    final mine = _mine(ref.watch(trainerRosterProvider), isOwner, senderId);
    final sender = ref.watch(trainersProvider).where((t) => t.id == trainerAuth);
    final from = isOwner
        ? kMarketplaceName
        : (sender.isNotEmpty ? sender.first.displayTitle : coachPublicName());
    final scope = _scope(mine, isOwner, senderId);
    final ways = _ways;
    final groupName = sanitizeGroupName(_groupName.text);
    final preview = previewBroadcast(
      ways: ways,
      recipients: scope.allowed,
      nowUtc: DateTime.now().toUtc(),
      refused: scope.refused.length,
    );

    if (_result != null) {
      return _Result(result: _result!, from: from);
    }
    if (_reviewing) {
      return _Review(
        groupName: groupName,
        from: from,
        ways: ways,
        preview: preview,
        busy: _sending,
        error: _error,
        onBack: () => setState(() => _reviewing = false),
        onSend: scope.allowed.isEmpty ? null : () => _send(scope),
      );
    }

    final query = _search.text.trim().toLowerCase();
    final shown = mine.where((c) => query.isEmpty || c.name.toLowerCase().contains(query)).toList();
    final canReview = groupName.isNotEmpty &&
        _message.text.trim().isNotEmpty &&
        scope.allowed.isNotEmpty &&
        broadcastWaysAllowed(_channels.map((c) => c.name).toSet()) &&
        (!ways.email || _subject.text.trim().isNotEmpty);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _Label("Group name"),
        AppField(
          controller: _groupName,
          kind: FieldKind.text,
          placeholder: "Name this group",
          maxLength: 40,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        Text("From $from", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          isOwner ? "Every client on the platform." : "Only your clients. Replies stay in each person's own chat.",
          style: TextStyle(color: AppColors.txt, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        const _Label("Who gets it"),
        _Choice(
          label: "All clients",
          detail: isOwner ? "${mine.length} on the platform" : "${mine.length} of yours",
          selected: _all,
          onTap: () => setState(() => _all = true),
        ),
        _Choice(
          label: "Choose clients",
          detail: _picked.isEmpty ? "Pick from the list" : "${_picked.length} picked",
          selected: !_all,
          onTap: () => setState(() => _all = false),
        ),
        if (!_all) ...[
          const SizedBox(height: 8),
          AppField(
            controller: _search,
            kind: FieldKind.name,
            placeholder: "Search clients",
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              BtnGhost(
                onPressed: () => setState(() => _picked.addAll(mine.map((c) => c.id))),
                child: const Text("Select all"),
              ),
              const SizedBox(width: 8),
              BtnGhost(
                onPressed: _picked.isEmpty ? null : () => setState(_picked.clear),
                child: const Text("Clear"),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final client in shown)
            _Choice(
              label: client.name,
              selected: _picked.contains(client.id),
              onTap: () => setState(() {
                if (!_picked.remove(client.id)) _picked.add(client.id);
              }),
            ),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text("No clients match that search.", style: TextStyle(color: AppColors.mute, fontSize: 13)),
            ),
        ],
        const SizedBox(height: 16),
        SendViaChips(
          channels: _channels,
          // Texts need the owner's "Text clients" switch for this coach.
          hidden: ref.watch(coachCanProvider(CoachPermission.sendTexts)) ? const {} : const {ChatChannel.sms},
          onChanged: (next) => setState(() => _channels = next),
        ),
        const SizedBox(height: 16),
        if (ways.email) ...[
          const _Label("Subject"),
          AppField(controller: _subject, kind: FieldKind.text, placeholder: "Subject", onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
        ],
        const _Label("Message"),
        AppField(
          controller: _message,
          kind: FieldKind.text,
          placeholder: "Write the message",
          minLines: 4,
          maxLines: 8,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        BtnGold(
          full: true,
          onPressed: canReview ? () => setState(() => _reviewing = true) : null,
          child: const Text("Review"),
        ),
      ],
    );
  }
}

class _Review extends StatelessWidget {
  const _Review({
    required this.groupName,
    required this.from,
    required this.ways,
    required this.preview,
    required this.busy,
    required this.error,
    required this.onBack,
    required this.onSend,
  });

  final String groupName;
  final String from;
  final BroadcastWays ways;
  final BroadcastPreview preview;
  final bool busy;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      "Group name: $groupName",
      "From $from",
      if (ways.app) "App chat: ${preview.app}",
      if (ways.sms) ...[
        "Text: ${preview.sms}",
        if (preview.skippedNoPhone > 0) "Skipped, no phone: ${preview.skippedNoPhone}",
        if (preview.skippedNoPhone == 0 && preview.sms == 0)
          "Texts use the number on file. The number is not shown here.",
        if (preview.skippedOptOut > 0) "Skipped, no text permission: ${preview.skippedOptOut}",
        if (preview.skippedQuietHours > 0) "Skipped, quiet hours: ${preview.skippedQuietHours}",
      ],
      if (ways.email) ...[
        "Email: ${preview.email}",
        if (preview.skippedNoEmail > 0) "Skipped, no email: ${preview.skippedNoEmail}",
      ],
      if (preview.refused > 0) "Left out, not a client: ${preview.refused}",
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _Label("Ready to send"),
        Text(
          "Each person gets their own copy. A reply comes back only to you.",
          style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 12),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(line, style: TextStyle(color: AppColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: TextStyle(color: AppColors.txt, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        BtnGold(
          full: true,
          onPressed: busy ? null : onSend,
          child: Text(busy ? "Sending…" : "Send"),
        ),
        const SizedBox(height: 8),
        BtnGhost(full: true, onPressed: busy ? null : onBack, child: const Text("Back")),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.result, required this.from});

  final Map<String, dynamic> result;
  final String from;

  int _n(String group, String key) {
    final box = result[group];
    if (box is! Map) return 0;
    final value = box[key];
    return value is num ? value.toInt() : 0;
  }

  Set<String> _asked(Map<String, dynamic> result) {
    final list = result["channels"];
    if (list is List && list.isNotEmpty) {
      return list.map((e) => e.toString()).toSet();
    }
    switch (result["channel"]?.toString()) {
      case "app":
        return {"inapp"};
      case "app_sms":
        return {"inapp", "sms"};
      case "email":
        return {"email"};
      default:
        return const {};
    }
  }

  @override
  Widget build(BuildContext context) {
    final asked = _asked(result);
    final lines = <String>[
      "From $from",
      if (asked.contains("inapp")) "App chat sent: ${_n("app", "sent")}",
      if (asked.contains("inapp") && _n("app", "failed") > 0) "App chat failed: ${_n("app", "failed")}",
      if (asked.contains("sms")) ...[
        "Texts sent: ${_n("sms", "sent")}",
        if (_n("sms", "skipped") > 0) "Texts skipped: ${_n("sms", "skipped")}",
        if (_n("sms", "failed") > 0) "Texts failed: ${_n("sms", "failed")}",
      ],
      if (asked.contains("email")) ...[
        "Emails sent: ${_n("email", "sent")}",
        if (_n("email", "skipped") > 0) "Emails skipped: ${_n("email", "skipped")}",
        if (_n("email", "failed") > 0) "Emails failed: ${_n("email", "failed")}",
      ],
      if ((result["refused"] is num) && (result["refused"] as num) > 0) "Left out: ${result["refused"]}",
      if ((result["rateLimited"] is num) && (result["rateLimited"] as num) > 0)
        "Waiting on the send limit: ${result["rateLimited"]}",
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _Label("Broadcast sent"),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(line, style: TextStyle(color: AppColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap, this.detail});

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TapHighlight(
        onTap: onTap,
        selected: selected,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold : AppColors.card,
            border: Border.all(color: selected ? AppColors.gold : AppColors.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.onGold : AppColors.txt,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              if (detail != null)
                Text(
                  detail!,
                  style: TextStyle(color: selected ? AppColors.onGold : AppColors.mute, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}
