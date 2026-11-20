import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/coach/coach_public_stats.dart";
import "package:onefitness/core/coach/review_prompt.dart";
import "package:onefitness/features/client/shell/session_rating_card.dart";

void main() {
  test("rebook percentage stays hidden until five clients", () {
    expect(rebookPercent(distinctClients: 4, clientsWithTwoOrMore: 3), isNull);
    expect(rebookPercent(distinctClients: 5, clientsWithTwoOrMore: 2), 40);
  });

  test("stars stay hidden until three reviews, and bars follow the counts", () {
    const few = StarCounts(five: 2);
    expect(few.showStars, isFalse);
    const enough = StarCounts(five: 2, four: 1);
    expect(enough.showStars, isTrue);
    expect(enough.fraction(5), closeTo(2 / 3, 0.001));
    expect(enough.countFor(1), 0);
  });

  test("not today hides a session until the next day and never gives up", () {
    const session = CheckedInSession(bookingId: "b1", trainerId: "t1", date: "2026-11-18");
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {},
        deferrals: const [ReviewDeferral(bookingId: "b1", deferredOn: "2026-11-20")],
        today: "2026-11-20",
      ),
      isNull,
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {},
        deferrals: const [ReviewDeferral(bookingId: "b1", deferredOn: "2026-11-20")],
        today: "2026-11-21",
      ),
      "b1",
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {"b1"},
        deferrals: const [],
        today: "2026-12-01",
      ),
      isNull,
    );
  });

  test("one open shows the newest unrated session", () {
    final id = nextSessionToRate(
      checkedIn: const [
        CheckedInSession(bookingId: "old", trainerId: "t", date: "2026-11-01"),
        CheckedInSession(bookingId: "new", trainerId: "t", date: "2026-11-18"),
      ],
      reviewedBookingIds: const {},
      deferrals: const [],
      today: "2026-11-20",
    );
    expect(id, "new");
  });

  test("a note is only allowed after stars are chosen", () {
    expect(reviewTextAllowed(0), isFalse);
    expect(reviewTextAllowed(4), isTrue);
  });

  testWidgets("the rating card has no skip and waits for stars", (tester) async {
    var submitted = 0;
    await tester.pumpWidget(MaterialApp(
      home: SessionRatingCard(
        coachName: "Coach Chris",
        onSubmit: (_, _) => submitted++,
        onNotToday: () {},
      ),
    ));
    expect(find.text("Skip"), findsNothing);
    expect(find.text("Not today"), findsOneWidget);
    expect(find.text("How was your session with Coach Chris?"), findsOneWidget);
    await tester.tap(find.text("Submit"));
    await tester.pump();
    expect(submitted, 0);
    await tester.tap(find.byIcon(Icons.star).at(4));
    await tester.pump();
    await tester.tap(find.text("Submit"));
    await tester.pump();
    expect(submitted, 1);
  });
}
