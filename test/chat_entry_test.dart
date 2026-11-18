import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/chat_entry.dart";
import "package:onefitness/core/utils/chat_channels.dart";

void main() {
  test("chat stays closed until there is a phone number", () {
    expect(chatMayOpen(phone: null), isFalse);
    expect(chatMayOpen(phone: "   "), isFalse);
    expect(chatMayOpen(phone: "555"), isFalse);
    expect(chatMayOpen(phone: "(818) 555-1212"), isTrue);
  });

  test("the first-open note names the tag and the 6-hour window", () {
    expect(kChatIntroBody, contains("@Coach"));
    expect(kChatIntroBody, contains("6 hours"));
    expect(kChatIntroOk, "OK, I understand.");
    expect(kChatIntroBody.toLowerCase().contains("password"), isFalse);
    expect(kChatIntroBody.contains("AI"), isFalse);
  });

  test("email is not saved on the chat message", () {
    expect(
      channelsSavedOnTheMessage({ChatChannel.inapp, ChatChannel.sms, ChatChannel.email}),
      {ChatChannel.inapp, ChatChannel.sms},
    );
    expect(channelsSavedOnTheMessage({ChatChannel.email}), isEmpty);
  });

  test("a new chat selects the app and SMS", () {
    expect(defaultChatChannels, {ChatChannel.inapp, ChatChannel.sms});
  });
}