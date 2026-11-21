import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/chat/staff_alert.dart";

void main() {
  test("the staff alert carries the saved message id", () {
    expect(
      chatToStaffNotifyFields(
        profileId: "coach-1",
        body: "Sam: In the lobby",
        messageId: "11111111-1111-1111-1111-111111111111",
      ),
      {
        "profileId": "coach-1",
        "body": "Sam: In the lobby",
        "messageId": "11111111-1111-1111-1111-111111111111",
      },
    );
  });
}
