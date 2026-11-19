import "dart:io";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/trainer_note.dart";
import "package:onefitness/data/models/workout_log.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/trainer/clients/client_activity.dart";
import "package:onefitness/features/trainer/clients/trainer_view.dart";

void main() {
  final now = DateTime(2026, 11, 19, 15);

  WorkoutLogEntry log(String date, {String? loggedAt, String day = "Push"}) =>
      WorkoutLogEntry(
        id: date,
        date: date,
        programId: "p",
        programName: "Strength",
        dayId: "d",
        dayTitle: day,
        loggedAt: loggedAt,
      );

  Booking visit(String date, {String? status, int slot = 9 * 60}) => Booking(
    id: date,
    clientId: "c",
    trainerId: "t",
    date: date,
    slot: slot,
    sessionType: "semi-private",
    discipline: "personal-training",
    attendanceStatus: status,
  );

  TrainerNote note(String createdAt, {String title = "Knee"}) => TrainerNote(
    id: createdAt,
    flag: "yellow",
    title: title,
    details: "Watch the depth",
    coachId: "t",
    coachName: "Coach Chris",
    createdAt: createdAt,
  );

  group("recent activity", () {
    test("newest first, five at most, future visits left out", () {
      final items = recentClientActivity(
        now: now,
        logs: [
          log("2026-11-19", loggedAt: "2026-11-19T14:00:00"),
          log("2026-11-10", day: "Legs"),
        ],
        bookings: [
          visit("2026-11-19", status: "checked-in", slot: 8 * 60),
          visit("2026-11-22"),
        ],
        notes: [note("2026-11-18T12:00:00")],
      );
      expect(items.map((e) => e.text).toList(), [
        "Logged Push",
        "Checked in",
        "Note · Knee",
        "Logged Legs",
      ]);
    });

    test("an empty client has nothing to show", () {
      expect(
        recentClientActivity(
          logs: const [],
          bookings: const [],
          notes: const [],
          now: now,
        ),
        isEmpty,
      );
    });

    test("relative dates", () {
      expect(relativeActivityWhen(DateTime(2026, 11, 19, 9), now), "Today");
      expect(relativeActivityWhen(DateTime(2026, 11, 18, 9), now), "Yesterday");
      expect(relativeActivityWhen(DateTime(2026, 11, 16, 9), now), "3d ago");
      expect(relativeActivityWhen(DateTime(2026, 10, 1, 9), now), "Oct 1");
    });
  });

  testWidgets("top tabs are Profile, Plans, Logged, Progress, and More", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: const MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: Key("client-view-shot"),
              child: TrainerView(clientId: "demo-jordan"),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final tabs = find.byKey(const Key("client-tabs"));
    for (final label in ["Profile", "Plans", "Logged", "Progress", "More"]) {
      expect(
        find.descendant(of: tabs, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: tabs, matching: find.text("Visits")),
      findsNothing,
    );
    expect(
      find.descendant(of: tabs, matching: find.text("Photos")),
      findsNothing,
    );
    expect(find.text("Message"), findsOneWidget);
    expect(find.text("Book"), findsOneWidget);
    expect(find.text("Log workout"), findsOneWidget);
    expect(find.text("Add note"), findsOneWidget);
    expect(find.text("Visit"), findsWidgets);

    try {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key("client-view-shot")),
      );
      final image = await tester.runAsync(
        () => boundary.toImage(pixelRatio: 2),
      );
      final bytes = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      Directory("/opt/cursor/artifacts").createSync(recursive: true);
      File(
        "/opt/cursor/artifacts/client-profile.png",
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    } catch (_) {}

    await tester.tap(find.descendant(of: tabs, matching: find.text("More")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final more = find.byKey(const Key("client-more"));
    for (final label in [
      "Visits",
      "Assessments",
      "Documents",
      "Habits",
      "Notes",
      "Squad",
      "Points",
    ]) {
      expect(
        find.descendant(of: more, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: more, matching: find.text("Photos")),
      findsNothing,
    );
    expect(
      find.descendant(of: more, matching: find.text("Badges")),
      findsNothing,
    );

    await tester.tap(
      find.descendant(of: tabs, matching: find.text("Progress")),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("PROGRESS PHOTOS"), findsOneWidget);
    expect(find.text("MEASUREMENTS"), findsOneWidget);
    expect(find.textContaining("MERIT BADGES"), findsWidgets);

    await tester.tap(find.descendant(of: tabs, matching: find.text("More")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key("client-more")),
        matching: find.text("Assessments"),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key("client-more")), findsNothing);
  });
}
