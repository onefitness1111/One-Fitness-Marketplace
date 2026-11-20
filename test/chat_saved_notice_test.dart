import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/widgets/chat_saved_notice.dart";

void main() {
  testWidgets("the chat footer names ONE Fitness Marketplace", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ChatSavedNotice())));
    expect(find.text("ONE Fitness Marketplace can see this chat."), findsOneWidget);
    expect(find.text("ONE Fitness can see this chat."), findsNothing);
  });
}
