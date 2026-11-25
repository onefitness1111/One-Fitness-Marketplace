import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/coach/coach_public_stats.dart";
import "package:onefitness/core/coach/review_prompt.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/features/client/shell/session_rating_card.dart";
import "package:onefitness/features/client/shell/session_rating_host.dart";

void main() {
  // 2026-11-24 14:00:00 America/Los_Angeles (PST = UTC-8) -> 22:00:00 UTC.
  final nowPt2pm = DateTime.utc(2026, 11, 24, 22, 0);

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

  test("in-progress checked-in session does not prompt until its Pacific end time passes", () {
    // 1:00 PM - 2:00 PM PT (slot 780, duration 60 -> ends 14:00 PT).
    const session = CheckedInSession(
      bookingId: "b1",
      trainerId: "t1",
      clientId: "c1",
      date: "2026-11-24",
      slot: 780,
      durationMin: 60,
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {},
        deferrals: const [],
        currentClientId: "c1",
        now: DateTime.utc(2026, 11, 24, 21, 59), // 1:59 PM PT
      ),
      isNull,
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {},
        deferrals: const [],
        currentClientId: "c1",
        now: nowPt2pm, // 2:00 PM PT
      ),
      "b1",
    );
  });

  test("dismissing with Not today hides the session permanently, and reviews never re-prompt", () {
    const session = CheckedInSession(
      bookingId: "b1",
      trainerId: "t1",
      clientId: "c1",
      date: "2026-11-24",
      slot: 600, // 10:00 AM - 11:00 AM PT
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {},
        deferrals: const [ReviewDeferral(bookingId: "b1", deferredOn: "2026-11-24")],
        currentClientId: "c1",
        now: nowPt2pm, // same day
      ),
      isNull,
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {},
        deferrals: const [ReviewDeferral(bookingId: "b1", deferredOn: "2026-11-24")],
        currentClientId: "c1",
        now: DateTime.utc(2026, 11, 25, 16, 0), // next day, still < 24h after 11 AM end
      ),
      isNull,
    );
    expect(
      nextSessionToRate(
        checkedIn: const [session],
        reviewedBookingIds: const {"b1"},
        deferrals: const [],
        currentClientId: "c1",
        now: nowPt2pm,
      ),
      isNull,
    );
  });

  test("only the newest recent finished session is eligible, with no backlog walking", () {
    const older = CheckedInSession(
      bookingId: "old-within-24h",
      trainerId: "t1",
      clientId: "c1",
      date: "2026-11-23",
      slot: 960, // 4:00 PM - 5:00 PM PT (ended 21h ago)
    );
    const newer = CheckedInSession(
      bookingId: "new-within-24h",
      trainerId: "t1",
      clientId: "c1",
      date: "2026-11-24",
      slot: 600, // 10:00 AM - 11:00 AM PT (ended 3h ago)
    );
    expect(
      nextSessionToRate(
        checkedIn: const [older, newer],
        reviewedBookingIds: const {},
        deferrals: const [],
        currentClientId: "c1",
        now: nowPt2pm,
      ),
      "new-within-24h",
    );
    // Once the newest finished session is dismissed or reviewed, do not walk back to older.
    expect(
      nextSessionToRate(
        checkedIn: const [older, newer],
        reviewedBookingIds: const {},
        deferrals: const [ReviewDeferral(bookingId: "new-within-24h", deferredOn: "2026-11-24")],
        currentClientId: "c1",
        now: nowPt2pm,
      ),
      isNull,
    );
    expect(
      nextSessionToRate(
        checkedIn: const [older, newer],
        reviewedBookingIds: const {"new-within-24h"},
        deferrals: const [],
        currentClientId: "c1",
        now: nowPt2pm,
      ),
      isNull,
    );
  });

  test("sessions older than 24h, cancelled, non-checked-in, or for another client are ignored", () {
    expect(
      nextSessionToRate(
        checkedIn: const [
          CheckedInSession(
            bookingId: "too-old",
            trainerId: "t1",
            clientId: "c1",
            date: "2026-11-23",
            slot: 720, // 12:00 PM - 1:00 PM PT (ended 25h ago)
          ),
          CheckedInSession(
            bookingId: "cancelled",
            trainerId: "t1",
            clientId: "c1",
            date: "2026-11-24",
            slot: 600,
            cancelled: true,
          ),
          CheckedInSession(
            bookingId: "no-show",
            trainerId: "t1",
            clientId: "c1",
            date: "2026-11-24",
            slot: 660,
            attendanceStatus: "no-show",
          ),
          CheckedInSession(
            bookingId: "other-client",
            trainerId: "t1",
            clientId: "c2",
            date: "2026-11-24",
            slot: 720,
          ),
        ],
        reviewedBookingIds: const {},
        deferrals: const [],
        currentClientId: "c1",
        now: nowPt2pm,
      ),
      isNull,
    );
  });

  test("rated booking ids keep the id and drop reviewer fields", () {
    expect(ratedBookingIds(["b1", "b2", ""]), {"b1", "b2"});
    expect(
      ratedBookingIds([
        {"booking_id": "b1", "client_id": "someone-else", "body": "great coach"},
      ]),
      {"b1"},
    );
    expect(ratedBookingIds(null), isEmpty);
  });

  test("the app asks for its own rated ids and the table stays closed", () {
    final sql = File("supabase/migrations/20261120185110_my_rated_booking_ids.sql").readAsStringSync();
    expect(sql, contains("security definer"));
    expect(sql, contains("set search_path to 'public'"));
    expect(sql, contains("select r.booking_id"));
    expect(sql, contains("r.client_id = (select auth.uid())"));
    expect(sql, isNot(contains("select *")));
    expect(sql.toLowerCase(), isNot(contains("for select")));
    expect(sql, contains("revoke all on function public.my_rated_booking_ids() from public, anon"));
    expect(sql, contains("grant execute on function public.my_rated_booking_ids() to authenticated"));
    expect(RegExp(r"my_rated_booking_ids\s*\([^)]+\)").hasMatch(sql), isFalse);

    final app = File("lib/core/supabase/supabase_service.dart").readAsStringSync();
    expect(app, contains('rpc("my_rated_booking_ids")'));
    expect(app, isNot(contains('from("coach_reviews").select')));
  });

  test("submit_coach_review migration and app RPC contract", () {
    final sql = File("supabase/migrations/20261124190000_submit_coach_review.sql").readAsStringSync();
    final lower = sql.toLowerCase();
    expect(lower, contains("create policy coach_reviews_select_own on public.coach_reviews"));
    expect(lower, contains("using (client_id = (select auth.uid()))"));
    expect(lower, contains("create or replace function public.submit_coach_review"));
    expect(lower, contains("security definer"));
    expect(lower, contains("set search_path = public"));
    expect(lower, contains("auth.uid()"));
    expect(lower, contains("v_booking.attendance_status is distinct from 'checked-in'"));
    expect(lower, contains("v_booking.cancelled_at is not null"));
    expect(lower, contains("v_booking.client_id <> v_uid"));
    expect(lower, contains("v_booking.trainer_id <> p_trainer_id"));
    expect(lower, contains("v_booking.ended_at > now()"));
    expect(lower, contains("america/los_angeles"));
    expect(lower, contains("revoke all on function public.submit_coach_review(uuid, uuid, integer, text) from public, anon"));
    expect(lower, contains("grant execute on function public.submit_coach_review(uuid, uuid, integer, text) to authenticated"));

    final app = File("lib/core/supabase/supabase_service.dart").readAsStringSync();
    expect(app, contains('rpc("submit_coach_review"'));
    expect(app, isNot(contains('from("coach_reviews").upsert')));
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

  testWidgets("host shows nothing when no recently finished unreviewed session exists", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(trainersProvider.notifier).setAll(const [
      Trainer(id: "t1", name: "Coach Chris"),
    ]);
    container.read(clientBookingsProvider.notifier).setAll([
      Booking(
        id: "b-future",
        clientId: "c1",
        trainerId: "t1",
        date: "2026-11-24",
        slot: 780, // 1:00 PM - 2:00 PM PT, still in progress at 1:30 PM PT
        sessionType: "personal",
        discipline: "strength",
        attendanceStatus: "checked-in",
      ),
      Booking(
        id: "b-stale",
        clientId: "c1",
        trainerId: "t1",
        date: "2026-11-22",
        slot: 600, // > 24h ago
        sessionType: "personal",
        discipline: "strength",
        attendanceStatus: "checked-in",
      ),
    ]);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SessionRatingHost(
          currentClientId: "c1",
          now: () => DateTime.utc(2026, 11, 24, 21, 30), // 1:30 PM PT
          loadState: () async => (reviewed: <String>{}, deferred: const <ReviewDeferral>[]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRatingCard), findsNothing);
  });

  testWidgets("host shows card once after finished session and never re-prompts after dismiss", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(trainersProvider.notifier).setAll(const [
      Trainer(id: "t1", name: "Coach Chris"),
    ]);
    container.read(clientBookingsProvider.notifier).setAll(const [
      Booking(
        id: "b1",
        clientId: "c1",
        trainerId: "t1",
        date: "2026-11-24",
        slot: 600, // 10:00 AM - 11:00 AM PT
        sessionType: "personal",
        discipline: "strength",
        attendanceStatus: "checked-in",
      ),
    ]);

    final deferred = <ReviewDeferral>[];
    var loadCalls = 0;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SessionRatingHost(
          currentClientId: "c1",
          now: () => nowPt2pm,
          loadState: () async {
            loadCalls++;
            return (reviewed: <String>{}, deferred: List<ReviewDeferral>.from(deferred));
          },
          deferReview: (bookingId, _) async {
            deferred.add(ReviewDeferral(bookingId: bookingId, deferredOn: "2026-11-24"));
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(loadCalls, 1);
    expect(find.byType(SessionRatingCard), findsOneWidget);

    await tester.tap(find.text("Not today"));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRatingCard), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(loadCalls, 2);
    expect(find.byType(SessionRatingCard), findsNothing);
  });

  testWidgets("host keeps card and shows error on failed submit, then clears after retry succeeds", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(trainersProvider.notifier).setAll(const [
      Trainer(id: "t1", name: "Coach Chris"),
    ]);
    container.read(clientBookingsProvider.notifier).setAll(const [
      Booking(
        id: "b1",
        clientId: "c1",
        trainerId: "t1",
        date: "2026-11-24",
        slot: 600,
        sessionType: "personal",
        discipline: "strength",
        attendanceStatus: "checked-in",
      ),
    ]);

    final reviewed = <String>{};
    var failNextSubmit = true;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SessionRatingHost(
          currentClientId: "c1",
          now: () => nowPt2pm,
          loadState: () async => (reviewed: Set<String>.from(reviewed), deferred: const <ReviewDeferral>[]),
          submitReview: ({required bookingId, required trainerId, required stars, body}) async {
            if (failNextSubmit) {
              throw Exception("403");
            }
            reviewed.add(bookingId);
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(SessionRatingCard), findsOneWidget);
    await tester.tap(find.byIcon(Icons.star).at(4));
    await tester.pump();
    await tester.tap(find.text("Submit"));
    await tester.pumpAndSettle();

    // Failed write keeps the card open and shows a short error.
    expect(find.byType(SessionRatingCard), findsOneWidget);
    expect(find.text("Could not save your review. Please try again."), findsOneWidget);
    expect(reviewed, isEmpty);

    // Retry succeeds: card clears and resume does not re-prompt.
    failNextSubmit = false;
    await tester.tap(find.text("Submit"));
    await tester.pumpAndSettle();

    expect(find.byType(SessionRatingCard), findsNothing);
    expect(reviewed, {"b1"});

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(SessionRatingCard), findsNothing);
  });
}
