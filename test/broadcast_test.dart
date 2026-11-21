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

  test("any mix of in app, text, and email is allowed, and empty is not", () {
    expect(broadcastWaysFromSet({"inapp"}), const BroadcastWays(app: true));
    expect(broadcastWaysFromSet({"inapp", "sms"}), const BroadcastWays(app: true, sms: true));
    expect(broadcastWaysFromSet({"email"}), const BroadcastWays(email: true));
    expect(broadcastWaysFromSet({"sms"}), const BroadcastWays(sms: true));
    expect(broadcastWaysFromSet({"email", "inapp"}), const BroadcastWays(app: true, email: true));
    expect(broadcastWaysFromSet({"inapp", "sms", "email"}), const BroadcastWays(app: true, sms: true, email: true));
    expect(broadcastWaysAllowed(const {}), isFalse);
    expect(broadcastLegacyWire(const BroadcastWays(app: true, sms: true)), "app_sms");
    expect(broadcastLegacyWire(const BroadcastWays(app: true, email: true)), isNull);
    expect(broadcastSummaryChannel(const BroadcastWays(app: true)), "app");
    expect(broadcastSummaryChannel(const BroadcastWays(app: true, sms: true)), "app_sms");
    expect(broadcastSummaryChannel(const BroadcastWays(email: true)), "email");
    expect(broadcastSummaryChannel(const BroadcastWays(app: true, sms: true, email: true)), "inapp,sms,email");
  });

  test("a group name is trimmed, flattened, and capped at 40 characters", () {
    expect(sanitizeGroupName("  Morning\ncrew  "), "Morning crew");
    expect(sanitizeGroupName(" \n "), "");
    expect(sanitizeGroupName("x" * 50).length, 40);
  });

  test("a coach reaches every client", () {
    final own = scopeBroadcast(
      senderIsOwner: false,
      senderId: "chris",
      all: true,
      requestedIds: const [],
      clients: clients,
    );
    expect(own.allowed.map((c) => c.id), ["a", "b", "c"]);
    expect(own.refused, isEmpty);

    final picked = scopeBroadcast(
      senderIsOwner: false,
      senderId: "chris",
      all: false,
      requestedIds: const ["a", "c"],
      clients: clients,
    );
    expect(picked.allowed.map((c) => c.id), ["a", "c"]);
    expect(picked.refused, isEmpty);
  });

  test("the owner reaches every client", () {
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
      ways: const BroadcastWays(app: true, sms: true),
      recipients: clients.where((c) => c.primaryTrainerId == "chris").toList(),
      nowUtc: DateTime.utc(2026, 1, 15, 18),
    );
    expect(open.app, 2);
    expect(open.sms, 1);
    expect(open.skippedNoPhone, 1);
    expect(open.email, 0);

    final quiet = previewBroadcast(
      ways: const BroadcastWays(app: true, sms: true),
      recipients: [clients.first],
      nowUtc: DateTime.utc(2026, 1, 15, 15),
    );
    expect(quiet.app, 1);
    expect(quiet.sms, 0);
    expect(quiet.skippedQuietHours, 1);

    final mail = previewBroadcast(
      ways: const BroadcastWays(email: true),
      recipients: [
        clients[1],
        person(id: "d", coach: "chris"),
      ],
      nowUtc: DateTime.utc(2026, 1, 15, 18),
    );
    expect(mail.app, 0);
    expect(mail.email, 1);
    expect(mail.skippedNoEmail, 1);

    final both = previewBroadcast(
      ways: const BroadcastWays(app: true, email: true),
      recipients: [clients[1]],
      nowUtc: DateTime.utc(2026, 1, 15, 18),
    );
    expect(both.app, 1);
    expect(both.email, 1);
  });

  test("someone who opted out is not texted, and the app chat still counts", () {
    final stopped = previewBroadcast(
      ways: const BroadcastWays(app: true, sms: true),
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
