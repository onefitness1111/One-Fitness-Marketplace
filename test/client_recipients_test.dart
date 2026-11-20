import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/client_recipients.dart";

void main() {
  test("a client cannot start a chat with the owner, and an old thread stays", () {
    final reach = clientRecipients(
      coachIds: const ["coach-1", "owner-1"],
      ownerIds: const {"owner-1"},
      messageTrainerIds: const ["coach-1", "owner-1", null],
    );
    expect(reach.pickerCoachIds, ["coach-1"]);
    expect(reach.historyIds, {"coach-1", "owner-1", "business"});
  });

  test("an owner with no messages is not invented in history", () {
    final reach = clientRecipients(
      coachIds: const ["coach-1"],
      ownerIds: const {"owner-1"},
      messageTrainerIds: const ["coach-1"],
    );
    expect(reach.pickerCoachIds, ["coach-1"]);
    expect(reach.historyIds.contains("owner-1"), isFalse);
  });
}
