import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/broadcast.dart";

BroadcastClient person({
  required String id,
  String? coach,
  String phone = "",
  String email = "",
  bool smsOptIn = false,
  bool smsOptedOut = false,
}) =>
    BroadcastClient(
      id: id,
      primaryTrainerId: coach,
      phone: phone,
      email: email,
      smsOptIn: smsOptIn,
      smsOptedOut: smsOptedOut,
    );

void main() {
  final clients = [
    person(id: "a", coach: "chris", phone: "5551112222", email: "a@gym.test", smsOptIn: true),
    person(id: "b", coach: "chris", email: "b@gym.test"),
    person(id: "c", coach: "pat", phone: "5553334444", email: "c@gym.test", smsOptIn: true),
  ];

  test("only app, app plus text, or email alone are allowed", () {
    expect(broadcastChannelFromSet({"inapp"}), BroadcastChannel.app);
    expect(broadcastChannelFromSet({"inapp", "sms"}), BroadcastChannel.appSms);
    expect(broadcastChannelFromSet({"email"}), BroadcastChannel.email);

    expect(broadcastChannelFromSet({"sms"}), isNull);
    expect(broadcastChannelFromSet({"email", "inapp"}), isNull);
    expect(broadcastChannelFromSet({"email", "sms"}), isNull);
    expect(broadcastChannelFromSet({"inapp", "sms", "email"}), isNull);
    expect(broadcastChannelFromSet({}), isNull);
    expect(broadcastChannelAllowed({"sms"}), isFalse);
  });

  test("a coach reaches only their own clients", () {
    final own = scopeBroadcast(
      senderIsOwner: false,
      senderId: "chris",
      all: true,
      requestedIds: const [],
      clients: clients,
    );
    expect(own.allowed.map((c) => c.id), ["a", "b"]);
    expect(own.refused, isEmpty);

    final picked = scopeBroadcast(
      senderIsOwner: false,
      senderId: "chris",
      all: false,
      requestedIds: const ["a", "c"],
      clients: clients,
    );
    expect(picked.allowed.map((c) => c.id), ["a"]);
    expect(picked.refused, ["c"]);
  });

  test("the owner reaches every client, including another coach's", () {
    final everyone = scopeBroadcast(
      senderIsOwner: true,
      senderId: "owner",
      all: false,
      requestedIds: const ["a", "c"],
      clients: clients,
    );
    expect(everyone.allowed.map((c) => c.id), ["a", "c"]);
    expect(everyone.refused, isEmpty);
  });

  test("texts are counted only when the person can be texted, and quiet hours skip them", () {
    final open = previewBroadcast(
      channel: BroadcastChannel.appSms,
      recipients: clients.where((c) => c.primaryTrainerId == "chris").toList(),
      nowUtc: DateTime.utc(2026, 1, 15, 18),
    );
    expect(open.app, 2);
    expect(open.sms, 1);
    expect(open.skippedNoPhone, 1);
    expect(open.email, 0);

    final quiet = previewBroadcast(
      channel: BroadcastChannel.appSms,
      recipients: [clients.first],
      nowUtc: DateTime.utc(2026, 1, 15, 15),
    );
    expect(quiet.app, 1);
    expect(quiet.sms, 0);
    expect(quiet.skippedQuietHours, 1);

    final mail = previewBroadcast(
      channel: BroadcastChannel.email,
      recipients: [
        clients[1],
        person(id: "d", coach: "chris"),
      ],
      nowUtc: DateTime.utc(2026, 1, 15, 18),
    );
    expect(mail.app, 0);
    expect(mail.email, 1);
    expect(mail.skippedNoEmail, 1);
  });

  test("someone who opted out is not texted, and the app chat still counts", () {
    final stopped = previewBroadcast(
      channel: BroadcastChannel.appSms,
      recipients: [
        person(id: "a", coach: "chris", phone: "555", smsOptIn: true, smsOptedOut: true),
      ],
      nowUtc: DateTime.utc(2026, 7, 15, 20),
    );
    expect(stopped.app, 1);
    expect(stopped.sms, 0);
    expect(stopped.skippedOptOut, 1);
  });
}
