import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/motion/booked_screen.dart";
import "package:onefitness/core/motion/pr_logic.dart";
import "package:onefitness/core/motion/stagger_in.dart";
import "package:onefitness/core/motion/workout_complete_gate.dart";

void main() {
  test("a heavier weight is a PR and the first log is not", () {
    expect(weightIsPersonalRecord(previousBest: 100, weight: 105), isTrue);
    expect(weightIsPersonalRecord(previousBest: 100, weight: 100), isFalse);
    expect(weightIsPersonalRecord(previousBest: 100, weight: null), isFalse);
    expect(weightIsPersonalRecord(previousBest: null, weight: 40), isFalse);
  });

  test("the same weight does not celebrate twice, and a new higher edit does", () {
    expect(
      shouldCelebratePr(previousBest: 80, weight: 90, lastCelebrated: null, appInForeground: true),
      isTrue,
    );
    expect(
      shouldCelebratePr(previousBest: 80, weight: 90, lastCelebrated: 90, appInForeground: true),
      isFalse,
    );
    expect(
      shouldCelebratePr(previousBest: 80, weight: 95, lastCelebrated: 90, appInForeground: true),
      isTrue,
    );
    expect(
      shouldCelebratePr(previousBest: 80, weight: 95, lastCelebrated: null, appInForeground: false),
      isFalse,
    );
  });

  test("old workouts are seeded as seen, and a new one shows once", () {
    final first = nextWorkoutComplete(
      logs: const [LoggedWorkout(id: "a", loggedAt: "2026-01-01", didWork: true)],
      storedSeen: null,
    );
    expect(first.showId, isNull);
    expect(first.seeded, isTrue);
    expect(first.seen, ["a"]);

    final next = nextWorkoutComplete(
      logs: const [
        LoggedWorkout(id: "a", loggedAt: "2026-01-01", didWork: true),
        LoggedWorkout(id: "b", loggedAt: "2026-02-01", didWork: true),
      ],
      storedSeen: first.seen,
    );
    expect(next.showId, "b");
    final after = nextWorkoutComplete(
      logs: const [
        LoggedWorkout(id: "a", loggedAt: "2026-01-01", didWork: true),
        LoggedWorkout(id: "b", loggedAt: "2026-02-01", didWork: true),
      ],
      storedSeen: ["a", "b"],
    );
    expect(after.showId, isNull);
  });

  testWidgets("a staggered row can be tapped before it finishes moving", (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StaggerIn(
          index: 8,
          child: TextButton(onPressed: () => taps++, child: const Text("Day 3")),
        ),
      ),
    ));
    await tester.tap(find.text("Day 3"));
    expect(taps, 1);
  });

  testWidgets("you're booked shows the details and Done immediately", (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: BookedScreen(when: "Mon at 9:00 AM", coach: "Coach Chris", place: "Burbank, CA"),
    ));
    expect(find.text("You're booked"), findsOneWidget);
    expect(find.text("Coach Chris"), findsOneWidget);
    expect(find.text("Done"), findsOneWidget);
  });
}
