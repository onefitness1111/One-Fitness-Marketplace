import "package:flutter_test/flutter_test.dart";
import "package:onefitness/features/trainer/chat/team_chat_screen.dart";

/// A coach used to see two ways to reach the business: the Marketplace
/// contact, and a separate person tile for the owner profile. The person
/// tile is gone from the new-chat lists. A direct thread that already
/// exists stays on the owner's id so those messages are not lost and are
/// not mixed into the Marketplace thread.
void main() {
  const me = "coach-1";
  final people = [
    {"id": "market", "name": "ONE Fitness Marketplace", "role": "market"},
    {"id": "owner-1", "name": "ONE Fitness", "role": "owner"},
    {"id": "coach-2", "name": "Coach Pat", "role": "coach"},
  ];

  test("a coach's new-chat list keeps Marketplace and coaches, not the owner", () {
    final choices = staffNewChatChoices(people, viewerIsOwner: false);
    expect(choices.map((p) => p["id"]), ["market", "coach-2"]);
    expect(choices.any((p) => p["role"] == "owner"), isFalse);
  });

  test("the owner still sees other owners when starting a chat", () {
    final choices = staffNewChatChoices(people, viewerIsOwner: true);
    expect(choices.map((p) => p["id"]), ["market", "owner-1", "coach-2"]);
  });

  test("a past direct thread with the owner stays its own history row", () {
    final messages = [
      {"sender_id": me, "recipient_id": "owner-1", "body": "Old note to you"},
      {"sender_id": me, "recipient_id": null, "body": "Hello business"},
    ];

    final direct = staffThreadMessages(
      key: "owner-1",
      me: me,
      viewerIsOwner: false,
      messages: messages,
    );
    final market = staffThreadMessages(
      key: "market",
      me: me,
      viewerIsOwner: false,
      messages: messages,
    );

    expect(direct.map((m) => m["body"]), ["Old note to you"]);
    expect(market.map((m) => m["body"]), ["Hello business"]);
    expect(market.any((m) => m["body"] == "Old note to you"), isFalse);
  });

  test("an owner with no direct messages does not invent a history row", () {
    final messages = [
      {"sender_id": me, "recipient_id": null, "body": "Hello business"},
    ];
    final direct = staffThreadMessages(
      key: "owner-1",
      me: me,
      viewerIsOwner: false,
      messages: messages,
    );
    expect(direct, isEmpty);
  });
}
