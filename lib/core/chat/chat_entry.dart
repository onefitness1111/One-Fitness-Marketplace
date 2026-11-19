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
    "When you reply by text, put @CoachName, like @Coach Chris, to reach that coach. "
    "A text with no name stays in the same conversation for 6 hours after the last message. "
    "After that, it goes to the business.";

const kCoachChatIntroBody =
    "When you reply by text, put @ClientName, like @Alex Johnson, so it reaches that client. "
    "A text with no name goes to the client you last messaged within 6 hours. "
    "After that, it goes to the business.";

const kOwnerChatIntroBody =
    "When you reply by text, put @CoachName, like @Coach Chris, to pass a business text to that coach, "
    "or @ClientName, like @Alex Johnson, to reach that client. "
    "A text with no name stays with the last conversation for 6 hours, then goes to the business.";

/// The first-open note for this signed-in role. Clients, coaches, and the
/// owner do not share one explanation.
String chatIntroBody(String role) => switch (role) {
      "coach" => kCoachChatIntroBody,
      "owner" => kOwnerChatIntroBody,
      _ => kChatIntroBody,
    };

const kChatIntroOk = "OK, I understand.";

/// Email is sent on its own and is never written onto the chat row.
Set<ChatChannel> channelsSavedOnTheMessage(Set<ChatChannel> channels) =>
    channels.where((c) => c != ChatChannel.email).toSet();
