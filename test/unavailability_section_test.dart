import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/unavailability.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/features/trainer/staff/unavailability_section.dart";

Booking session({
  required String id,
  required String clientId,
  int slot = 9 * 60,
  String sessionType = "semi-private",
}) =>
    Booking(
      id: id,
      clientId: clientId,
      trainerId: "coach-1",
      date: "2026-11-25",
      slot: slot,
      sessionType: sessionType,
      discipline: "strength",
    );

void main() {
  testWidgets("the time toggle switches between all day, from a time, and a range", (tester) async {
    var mode = UnavailabilityTimeMode.allDay;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => UnavailabilityTimeToggle(
            mode: mode,
            onChanged: (next) => setState(() => mode = next),
          ),
        ),
      ),
    ));

    expect(find.text("All day"), findsOneWidget);
    expect(find.text("From a time"), findsOneWidget);
    expect(find.text("Time range"), findsOneWidget);

    await tester.tap(find.text("From a time"));
    await tester.pump();
    expect(mode, UnavailabilityTimeMode.fromTime);

    await tester.tap(find.text("Time range"));
    await tester.pump();
    expect(mode, UnavailabilityTimeMode.range);

    await tester.tap(find.text("All day"));
    await tester.pump();
    expect(mode, UnavailabilityTimeMode.allDay);
  });

  testWidgets("the add form shows one time for from-a-time and two for a range", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UnavailabilitySection(
          trainerId: "coach-1",
          entries: const [],
          bookings: const [],
          onChange: (_) {},
          onSave: (_) async => const UnavailabilitySaveResult(cancelled: 0, bookingIds: []),
        ),
      ),
    ));

    await tester.tap(find.text("Add Unavailability"));
    await tester.pumpAndSettle();
    expect(find.text("From"), findsNothing);
    expect(find.text("Start"), findsNothing);

    await tester.tap(find.text("From a time"));
    await tester.pumpAndSettle();
    expect(find.text("From"), findsOneWidget);
    expect(find.text("9:00 AM"), findsOneWidget);

    await tester.tap(find.text("Time range"));
    await tester.pumpAndSettle();
    expect(find.text("Start"), findsOneWidget);
    expect(find.text("End"), findsWidgets);
    expect(find.text("9:00 AM"), findsOneWidget);
    expect(find.text("5:00 PM"), findsOneWidget);
  });

  testWidgets("the preview lists the session and the button names how many it cancels", (tester) async {
    final sessions = affectedSessionsFor(
      const TrainerUnavailability(
        id: "u1",
        startDate: "2026-11-25",
        endDate: "2026-11-25",
        allDay: true,
        reason: "Vacation",
      ),
      [
        session(id: "b1", clientId: "c1"),
        session(id: "b2", clientId: "c2"),
      ],
      trainerId: "coach-1",
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UnavailabilityPreviewCard(sessions: sessions, saving: false, onSave: () {}),
      ),
    ));

    expect(find.text("This will cancel 1 session"), findsOneWidget);
    expect(find.textContaining("Semi-Private"), findsOneWidget);
    expect(find.textContaining("2 clients"), findsOneWidget);
    expect(find.text("Save and cancel 1 session"), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UnavailabilityPreviewCard(sessions: const [], saving: false, onSave: () {}),
      ),
    ));
    expect(find.text("This will cancel 0 sessions"), findsOneWidget);
    expect(find.text("Save"), findsOneWidget);
  });

  testWidgets("removing a block says cancelled sessions stay cancelled", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UnavailabilitySection(
          trainerId: "coach-1",
          entries: const [
            TrainerUnavailability(
              id: "u1",
              startDate: "2026-11-25",
              endDate: "2026-11-27",
              allDay: false,
              startMin: 14 * 60,
              reason: "Appointment",
            ),
          ],
          bookings: const [],
          onChange: (_) {},
          onRemove: (_) async {},
        ),
      ),
    ));

    expect(find.textContaining("Appointment"), findsOneWidget);
    expect(find.textContaining("From 2:00 PM"), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    expect(find.text("Remove this time off?"), findsOneWidget);
    expect(
      find.text("Clients will be able to book these times again. Sessions that were already cancelled stay cancelled."),
      findsOneWidget,
    );
  });
}
