import "../utils/chat_channels.dart";

/// A profile phone is required before chat opens. Same bar as the rest of
/// the app: enough digits to be a real number.
bool hasProfilePhone(String? phone) {
  final digits = (phone ?? "").replaceAll(RegExp(r"[^0-9]"), "");
  return digits.length >= 7;
}

/// Chat stays closed until a number is saved. Cancelling the prompt does
/// not open the thread.
bool chatMayOpen({required String? phone}) => hasProfilePhone(phone);

const kChatIntroTitle = "How texts find the right chat";

const kChatIntroBody =
    "Put @CoachName in the message, like @Coach Chris, to reach that coach. "
    "A text with no name stays in the same conversation for 6 hours after the last message. "
    "After that, it goes to the business.";

const kChatIntroOk = "OK, I understand.";

/// Email is sent on its own and is never written onto the chat row.
Set<ChatChannel> channelsSavedOnTheMessage(Set<ChatChannel> channels) =>
    channels.where((c) => c != ChatChannel.email).toSet();
