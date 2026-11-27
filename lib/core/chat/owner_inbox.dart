import "../../data/models/client_info.dart";
import "../../data/models/comm_message.dart";
import "../../data/models/trainer.dart";
import "../utils/coach_names.dart";
import "../utils/chat_channels.dart";

/// Filter value for every coach plus the business threads.
const kOwnerFilterAll = "all";

/// A thread with the gym, including texts routed to the business.
const kOwnerBusinessKey = "business";

/// The name on a business row. Clients still only see coach names.
const kOneFitnessLabel = kMarketplaceName;

/// The business choice in the coach filter.
const kOneFitnessBusinessLabel = "$kMarketplaceName (business)";

/// Staff-to-staff threads, when any exist. Also the name of the filter that
/// shows only those threads (U3: Coach Chats is a filter inside Chat, not a
/// tab or a separate screen).
const kTeamChatLabel = "Coach Chats";

/// Filter value for staff-to-staff threads only.
const kOwnerCoachChatsKey = "coach-chats";

/// Shown above the composer's send box so an owner reply is not mistaken
/// for the coach in that thread.
const kOwnerReplyLabel = "ONE Fitness";

/// One row in the owner's Chat list.
class OwnerInboxRow {
  const OwnerInboxRow({
    required this.id,
    required this.clientId,
    required this.coachKey,
    required this.title,
    required this.coachLabel,
    required this.preview,
    required this.at,
    required this.unread,
    this.photo,
    this.outgoing = false,
    this.team = false,
    this.participantIds = const {},
  });

  /// `client:<clientId>:<coachKey>` or a staff id (`staff:…`, `pair:…`).
  final String id;
  final String? clientId;

  /// A coach id, [kOwnerBusinessKey], or a staff key.
  final String coachKey;
  final String title;
  final String coachLabel;
  final String preview;
  final DateTime at;
  final bool unread;
  final String? photo;
  final bool outgoing;

  /// A coach-to-coach or business staff thread, not a client thread.
  final bool team;

  /// Coach ids in a team thread, used by the coach filter.
  final Set<String> participantIds;
}

class OwnerCoachOption {
  const OwnerCoachOption({required this.key, required this.label});

  final String key;
  final String label;
}

/// Which thread a message belongs to. A text routed to the business stays
/// with ONE Fitness even when a coach id is also stored on the row.
String ownerThreadCoachKey(CommMessage message, Set<String> ownerIds) {
  if (message.routedTo == kOwnerBusinessKey) return kOwnerBusinessKey;
  final trainer = message.trainerId?.trim() ?? "";
  if (trainer.isEmpty || trainer == kOwnerBusinessKey || ownerIds.contains(trainer)) {
    return kOwnerBusinessKey;
  }
  return trainer;
}

String ownerThreadId(String clientId, String coachKey) => "client:$clientId:$coachKey";

String ownerUnreadKey(String clientId, String coachKey) => "owner:$clientId:$coachKey";

/// `client:<uuid>:<coach uuid or business>`, or null when it is a team row.
({String clientId, String coachKey})? parseOwnerThreadId(String id) {
  if (!id.startsWith("client:")) return null;
  final rest = id.substring("client:".length);
  final split = rest.indexOf(":");
  if (split <= 0 || split >= rest.length - 1) return null;
  return (clientId: rest.substring(0, split), coachKey: rest.substring(split + 1));
}

/// All coaches, Coach Chats (staff-to-staff threads only), each coach by
/// coach name, then the business.
///
/// Coach names come from [Trainer.displayTitle]. A legal name is never used.
List<OwnerCoachOption> ownerCoachFilters(Iterable<Trainer> coaches) {
  final list = coaches.toList()
    ..sort((a, b) => a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()));
  return [
    const OwnerCoachOption(key: kOwnerFilterAll, label: "All coaches"),
    const OwnerCoachOption(key: kOwnerCoachChatsKey, label: kTeamChatLabel),
    for (final coach in list) OwnerCoachOption(key: coach.id, label: coach.displayTitle),
    const OwnerCoachOption(key: kOwnerBusinessKey, label: kOneFitnessBusinessLabel),
  ];
}

/// Every client thread the owner should see, newest activity first.
///
/// One row per client and coach. Business messages, including inbound SMS
/// routed to the business, are their own rows labeled [kOneFitnessLabel].
/// Assignment on the client is not read.
List<OwnerInboxRow> ownerClientThreads({
  required List<ClientInfo> roster,
  required Map<String, List<CommMessage>> commsByClient,
  required List<Trainer> coaches,
  required Set<String> ownerIds,
  required Set<String> unreadKeys,
}) {
  final coachNames = {for (final coach in coaches) coach.id: coach.displayTitle};
  final rows = <OwnerInboxRow>[];
  for (final client in roster) {
    final comms = commsByClient[client.id] ?? const <CommMessage>[];
    final grouped = <String, List<CommMessage>>{};
    for (final message in comms) {
      grouped.putIfAbsent(ownerThreadCoachKey(message, ownerIds), () => []).add(message);
    }
    for (final entry in grouped.entries) {
      final messages = entry.value..sort((a, b) => b.sentAt.compareTo(a.sentAt));
      final last = messages.first;
      final business = entry.key == kOwnerBusinessKey;
      // Each staff member has their own read marks (thread_reads, via
      // my_unread_chat_keys). The shared read_by_coach flag is not used.
      final unread = unreadKeys.contains(ownerUnreadKey(client.id, entry.key)) ||
          (business && unreadKeys.contains(client.id));
      rows.add(OwnerInboxRow(
        id: ownerThreadId(client.id, entry.key),
        clientId: client.id,
        coachKey: entry.key,
        title: client.name,
        coachLabel: business ? kOneFitnessLabel : (coachNames[entry.key] ?? coachPublicName()),
        preview: last.text,
        at: last.sentAt,
        unread: unread,
        photo: client.photo,
        outgoing: last.who == "trainer",
      ));
    }
  }
  rows.sort((a, b) => b.at.compareTo(a.at));
  return rows;
}

/// Messages in one owner thread, oldest first.
List<CommMessage> messagesForOwnerThread(
  List<CommMessage> comms, {
  required String coachKey,
  required Set<String> ownerIds,
}) {
  final thread = comms.where((m) => ownerThreadCoachKey(m, ownerIds) == coachKey).toList()
    ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
  return thread;
}

/// Applies the coach filter and a client-name search. Team rows stay on
/// All coaches, and on the coach or business they belong to.
List<OwnerInboxRow> filterOwnerInbox(
  List<OwnerInboxRow> rows, {
  required String coachKey,
  String query = "",
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final row in rows)
      if (_matchesCoach(row, coachKey) && (q.isEmpty || row.title.toLowerCase().contains(q))) row,
  ];
}

bool _matchesCoach(OwnerInboxRow row, String coachKey) {
  if (coachKey == kOwnerFilterAll) return true;
  if (coachKey == kOwnerCoachChatsKey) return row.team;
  if (row.team) {
    if (coachKey == kOwnerBusinessKey) return row.coachKey == kOwnerBusinessKey;
    return row.participantIds.contains(coachKey);
  }
  return row.coachKey == coachKey;
}
