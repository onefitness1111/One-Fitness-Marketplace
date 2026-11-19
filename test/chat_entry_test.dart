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

  test("the first-open note depends on who is signed in", () {
    expect(chatIntroBody("client"), kChatIntroBody);
    expect(kChatIntroBody, contains("@Coach Chris"));
    expect(kChatIntroBody, contains("6 hours"));
    expect(chatIntroBody("coach"), contains("@Alex Johnson"));
    expect(chatIntroBody("coach"), contains("6 hours"));
    expect(chatIntroBody("owner"), contains("@Coach Chris"));
    expect(chatIntroBody("owner"), contains("@Alex Johnson"));
    expect(kChatIntroOk, "OK, I understand.");
    for (final body in [kChatIntroBody, chatIntroBody("coach"), chatIntroBody("owner")]) {
      expect(body.toLowerCase().contains("password"), isFalse);
      expect(body.contains("AI"), isFalse);
    }
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