import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/coach_thread_scope.dart";
import "package:onefitness/data/models/comm_message.dart";

CommMessage msg(String? trainerId) => CommMessage(
      id: "m-${trainerId ?? "none"}",
      who: "client",
      text: "hi",
      at: "now",
      trainerId: trainerId,
    );

void main() {
  test("a coach sees only their own thread", () {
    expect(staffSeesMessage(msg("coach-a"), isOwner: false, trainerAuth: "coach-a"), isTrue);
    expect(staffSeesMessage(msg("coach-b"), isOwner: false, trainerAuth: "coach-a"), isFalse);
  });

  test("a coach does not see the Business Chat", () {
    expect(staffSeesMessage(msg(null), isOwner: false, trainerAuth: "coach-a"), isFalse);
    expect(staffSeesMessage(msg("owner-id"), isOwner: false, trainerAuth: "coach-a"), isFalse);
  });

  test("the owner sees everything", () {
    expect(staffSeesMessage(msg(null), isOwner: true, trainerAuth: "owner"), isTrue);
    expect(staffSeesMessage(msg("coach-b"), isOwner: true, trainerAuth: "owner"), isTrue);
  });
}
