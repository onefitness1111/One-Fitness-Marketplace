/// Fields for client-notify `chat-to-staff`.
///
/// [messageId] is the saved messages row. The server uses it so this push
/// and the one from the database trigger are not both delivered.
Map<String, dynamic> chatToStaffNotifyFields({
  required String profileId,
  required String body,
  required String messageId,
}) {
  return {
    "profileId": profileId,
    "body": body,
    "messageId": messageId,
  };
}
