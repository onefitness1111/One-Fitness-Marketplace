import "../../data/models/comm_message.dart";

/// Which client-thread messages a staff member sees in the coach app.
///
/// Coach Chris (Nov 27, 2026): coaches see only their own chats. A coach's
/// chat is the thread whose trainer is that coach — their own messages, the
/// client's replies, and anything the owner placed in it. Not the Business
/// Chat (no trainer, or the owner) and not another coach's thread. The owner
/// sees everything. Never keyed on a client's primary coach.
///
/// The database enforces the same rule (messages_select); this keeps the
/// lists and unread dots in step with it.
bool staffSeesMessage(CommMessage m, {required bool isOwner, required String? trainerAuth}) {
  if (isOwner) return true;
  if (trainerAuth == null || trainerAuth.isEmpty) return false;
  return m.trainerId == trainerAuth;
}
