import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/utils/chat_channels.dart";
import "package:onefitness/core/widgets/send_via_chips.dart";
import "package:onefitness/features/client/chat/chat_screen.dart";

void main() {
  test("business messaging drops SMS and keeps a channel", () {
    expect(withoutBusinessSms({ChatChannel.inapp, ChatChannel.sms}), {ChatChannel.inapp});
    expect(withoutBusinessSms({ChatChannel.sms}), {ChatChannel.inapp});
    expect(
      withoutBusinessSms({ChatChannel.sms, ChatChannel.email}),
      {ChatChannel.email},
    );
    expect(withoutBusinessSms({ChatChannel.inapp}), {ChatChannel.inapp});
  });

  testWidgets("client send-via offers In app, SMS, and Email", (tester) async {
    var channels = {ChatChannel.inapp, ChatChannel.sms};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ClientSendViaSection(
            channels: channels,
            businessSelected: false,
            needsPhone: false,
            onChanged: (next) => setState(() => channels = next),
          ),
        ),
      ),
    ));

    expect(find.text("In app"), findsOneWidget);
    expect(find.text("SMS"), findsOneWidget);
    expect(find.text("Email"), findsOneWidget);
    expect(find.text("In app alerts your coach. Texts and emails are sent by ONE Fitness, not from your personal number or email."), findsOneWidget);

    await tester.tap(find.text("Email"));
    await tester.pump();
    expect(channels.contains(ChatChannel.email), isTrue);

    await tester.tap(find.text("SMS"));
    await tester.pump();
    expect(channels.contains(ChatChannel.sms), isFalse);
    expect(channels.contains(ChatChannel.inapp), isTrue);
  });

  testWidgets("business hides SMS and a missing phone is a tappable hint", (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClientSendViaSection(
          channels: {ChatChannel.inapp, ChatChannel.email},
          businessSelected: true,
          needsPhone: true,
          onChanged: (_) {},
          onAddPhone: () => tapped = true,
        ),
      ),
    ));

    expect(find.text("SMS"), findsNothing);
    expect(find.text("In app"), findsOneWidget);
    expect(find.text("Email"), findsOneWidget);
    expect(find.text("Texts aren't available for ONE Fitness Marketplace."), findsOneWidget);

    await tester.tap(find.text("Add a phone number in Profile Settings to get texts"));
    expect(tapped, isTrue);
  });

  testWidgets("the last send-via chip cannot be turned off", (tester) async {
    var channels = {ChatChannel.inapp};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SendViaChips(
            channels: channels,
            onChanged: (next) => setState(() => channels = next),
          ),
        ),
      ),
    ));
    await tester.tap(find.text("In app"));
    await tester.pump();
    expect(channels, {ChatChannel.inapp});
  });
}
