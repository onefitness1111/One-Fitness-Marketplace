import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/unread_threads.dart";

void main() {
  final earlier = DateTime.utc(2026, 11, 18, 12);
  final later = earlier.add(const Duration(minutes: 5));
  const me = "client-1";
  const coach = "coach-1";

  test("a message after last-read from someone else is unread, including broadcast and business", () {
    final business = clientThreadKey(clientId: me, trainerIsOwner: true);
    final pair = clientThreadKey(clientId: me, trainerId: coach);
    final messages = [
      ChatLine(threadKey: pair, senderId: coach, at: later),
      ChatLine(threadKey: business, senderId: "owner-1", at: later),
      ChatLine(threadKey: pair, senderId: me, at: later),
    ];
    final reads = [
      ThreadRead(userId: me, threadKey: pair, lastReadAt: earlier),
    ];
    final unread = unreadThreadKeys(viewerId: me, messages: messages, reads: reads);
    expect(unread, {pair, business});
    expect(showsChatDot(unread), isTrue);
    expect(chatListKey(threadKey: pair, viewerId: me, viewerIsClient: true), coach);
    expect(chatListKey(threadKey: business, viewerId: me, viewerIsClient: true), "business");
    expect(chatListKey(threadKey: pair, viewerId: coach, viewerIsClient: false), me);
  });

  test("opening the thread clears that dot and leaves the other one", () {
    final pair = clientThreadKey(clientId: me, trainerId: coach);
    final business = clientThreadKey(clientId: me);
    final read = markThreadRead(userId: me, threadKey: pair, at: later);
    final unread = unreadThreadKeys(
      viewerId: me,
      messages: [
        ChatLine(threadKey: pair, senderId: coach, at: earlier),
        ChatLine(threadKey: business, senderId: "owner-1", at: later),
      ],
      reads: [read],
    );
    expect(unread.contains(pair), isFalse);
    expect(unread, {business});
  });

  test("a person only sees their own read state", () {
    expect(readStateVisibleTo(markUserId: me, viewerId: me), isTrue);
    expect(readStateVisibleTo(markUserId: me, viewerId: coach), isFalse);
  });

  test("staff and marketplace threads use their own keys", () {
    expect(staffThreadKey(senderId: coach, recipientId: null), "staff:market");
    expect(staffThreadKey(senderId: coach, recipientId: "owner-1"), "staff:coach-1:owner-1");
    final key = staffThreadKey(senderId: "owner-1", recipientId: coach);
    final unread = unreadThreadKeys(
      viewerId: coach,
      messages: [ChatLine(threadKey: key, senderId: "owner-1", at: later)],
      reads: const [],
    );
    expect(showsChatDot(unread), isTrue);
    expect(chatListKey(threadKey: key, viewerId: coach, viewerIsClient: false), "staff:owner-1");
  });

  test("caught up means no dot", () {
    final pair = clientThreadKey(clientId: me, trainerId: coach);
    final unread = unreadThreadKeys(
      viewerId: me,
      messages: [ChatLine(threadKey: pair, senderId: coach, at: earlier)],
      reads: [ThreadRead(userId: me, threadKey: pair, lastReadAt: later)],
    );
    expect(unread, isEmpty);
    expect(showsChatDot(unread), isFalse);
  });
}
