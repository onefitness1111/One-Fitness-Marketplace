/// Who a client may message.
///
/// A new chat offers their coaches and ONE Fitness Marketplace. An owner
/// profile is never a new contact. A direct thread that already exists with
/// the owner stays in history and is not folded into Marketplace.
class ClientRecipients {
  const ClientRecipients({required this.pickerCoachIds, required this.historyIds});

  /// Coach profile ids offered on "Who are you messaging?".
  final List<String> pickerCoachIds;

  /// Thread ids to show in history: "business", a coach id, or an owner id
  /// that already has messages.
  final Set<String> historyIds;
}

ClientRecipients clientRecipients({
  required Iterable<String> coachIds,
  required Set<String> ownerIds,
  required Iterable<String?> messageTrainerIds,
}) {
  final coaches = coachIds.where((id) => id.isNotEmpty && !ownerIds.contains(id)).toList();
  final history = <String>{};
  var business = false;
  for (final raw in messageTrainerIds) {
    final id = (raw ?? "").trim();
    if (id.isEmpty) {
      business = true;
      continue;
    }
    if (coaches.contains(id) || ownerIds.contains(id)) history.add(id);
  }
  if (business) history.add("business");
  return ClientRecipients(pickerCoachIds: coaches, historyIds: history);
}
