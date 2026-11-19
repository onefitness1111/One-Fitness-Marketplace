import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/utils/session_start.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/live_session.dart";
import "package:onefitness/core/widgets/session_timer.dart";

/// When a coach may start a session, how many may be live at once, and what
/// the running clock shows. The dashboard calls these same functions.
void main() {
  const today = "2026-10-10";
  const ninePm = 21 * 60;

  bool mayStart({
    required String viewDate,
    required int nowMin,
    required bool someoneCheckedIn,
    bool alreadyLive = false,
    int slot = ninePm,
  }) =>
      sessionMayStart(
        viewDate: viewDate,
        today: today,
        nowMin: nowMin,
        slot: slot,
        someoneCheckedIn: someoneCheckedIn,
        alreadyLive: alreadyLive,
      );

  Booking booking({String? attendanceStatus, String? clientStartedAt}) => Booking(
        id: "b1",
        clientId: "c1",
        trainerId: "t1",
        date: today,
        slot: ninePm,
        sessionType: "semi-private",
        discipline: "personal-training",
        attendanceStatus: attendanceStatus,
        clientStartedAt: clientStartedAt,
      );

  group("when a coach may start a session", () {
    test("not in the morning for a session that evening", () {
      // The reported bug, exactly: 9:52am, session at 9:00pm.
      expect(
        mayStart(viewDate: today, nowMin: 9 * 60 + 52, someoneCheckedIn: false),
        isFalse,
      );
    });

    test("not a minute before it is due", () {
      expect(
        mayStart(viewDate: today, nowMin: ninePm - 1, someoneCheckedIn: false),
        isFalse,
      );
    });

    test("yes, on the minute", () {
      expect(
        mayStart(viewDate: today, nowMin: ninePm, someoneCheckedIn: false),
        isTrue,
      );
    });

    test("yes, once it is under way", () {
      expect(
        mayStart(viewDate: today, nowMin: ninePm + 30, someoneCheckedIn: false),
        isTrue,
      );
    });

    test("never for a session on a future day", () {
      expect(
        mayStart(viewDate: "2026-10-11", nowMin: 23 * 60, someoneCheckedIn: false),
        isFalse,
      );
    });

    test("a future day opens once someone in it is checked in", () {
      expect(
        mayStart(viewDate: "2026-10-11", nowMin: 23 * 60, someoneCheckedIn: true),
        isTrue,
      );
    });

    test("a past day stays closed", () {
      expect(
        mayStart(viewDate: "2026-10-09", nowMin: ninePm + 30, someoneCheckedIn: true),
        isFalse,
      );
    });

    test("a past day can still be rejoined while it is live", () {
      expect(
        mayStart(viewDate: "2026-10-09", nowMin: ninePm, someoneCheckedIn: false, alreadyLive: true),
        isTrue,
      );
    });

    test("the wait line names the scheduled time until the gate opens", () {
      expect(
        sessionStartHint(
          viewDate: today,
          today: today,
          nowMin: 8 * 60 + 22,
          slot: 9 * 60,
          someoneCheckedIn: false,
        ),
        "Can be started at 9:00 AM, or as soon as someone checks in",
      );
    });

    test("the wait line goes away once someone is checked in", () {
      expect(
        sessionStartHint(
          viewDate: today,
          today: today,
          nowMin: 8 * 60 + 22,
          slot: 9 * 60,
          someoneCheckedIn: true,
        ),
        isNull,
      );
    });

    test("the wait line goes away once the scheduled time arrives", () {
      expect(
        sessionStartHint(
          viewDate: today,
          today: today,
          nowMin: 9 * 60,
          slot: 9 * 60,
          someoneCheckedIn: false,
        ),
        isNull,
      );
    });
  });

  group("the early-arrival exception", () {
    // A client can start their own session early. If the coach were hard
    // blocked until the slot time, that client would be training with no
    // live session — and so no way to beep their coach.
    test("a client checking in early unlocks the coach's start", () {
      expect(
        mayStart(viewDate: today, nowMin: 18 * 60, someoneCheckedIn: true),
        isTrue,
      );
    });

    test("without an early arrival it stays blocked at the same moment", () {
      expect(
        mayStart(viewDate: today, nowMin: 18 * 60, someoneCheckedIn: false),
        isFalse,
      );
    });
  });

  group("the running clock", () {
    LiveSession runStarted(Duration ago, {int durationMin = 60}) => LiveSession(
          id: "run-1",
          trainerId: "coach-1",
          date: today,
          slotMin: ninePm,
          sessionType: "semi-private",
          durationMin: durationMin,
          startedAt: DateTime.now().toUtc().subtract(ago).toIso8601String(),
        );

    Future<String> shown(WidgetTester tester, LiveSession run) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SessionTimer(run: run))));
      final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
      return texts.firstWhere((t) => t != null && RegExp(r"^\d+:\d{2}").hasMatch(t))!;
    }

    /// The clock is read a fraction of a second after the start time is
    /// built, so an exact match would be flaky by one second. Seconds-level
    /// tolerance still catches a clock counting the wrong way, from the
    /// wrong origin, or from the wrong duration.
    void expectAbout(String shownText, Duration expected) {
      final parts = shownText.split(":").map(int.parse).toList();
      final seconds = parts.length == 3
          ? parts[0] * 3600 + parts[1] * 60 + parts[2]
          : parts[0] * 60 + parts[1];
      expect(seconds, closeTo(expected.inSeconds, 2), reason: "showed $shownText");
    }

    testWidgets("counts DOWN from the session's length", (tester) async {
      // Twelve minutes in, forty-eight left of the hour.
      expectAbout(await shown(tester, runStarted(const Duration(minutes: 12))), const Duration(minutes: 48));
    });

    testWidgets("counts from when the session started, not from first build", (tester) async {
      // Backing out and returning rebuilds this widget; the clock must not
      // restart.
      expectAbout(await shown(tester, runStarted(const Duration(minutes: 12, seconds: 5))),
          const Duration(minutes: 47, seconds: 55));
    });

    testWidgets("a 30-minute session counts down from 30, not 60", (tester) async {
      expectAbout(await shown(tester, runStarted(const Duration(minutes: 5), durationMin: 30)),
          const Duration(minutes: 25));
    });

    testWidgets("a 90-minute session shows hours", (tester) async {
      final text = await shown(tester, runStarted(Duration.zero, durationMin: 90));
      expect(text.split(":").length, 3, reason: "should read h:mm:ss, got $text");
      expectAbout(text, const Duration(minutes: 90));
    });

    testWidgets("never goes negative once the time is up", (tester) async {
      expect(await shown(tester, runStarted(const Duration(minutes: 75))), "0:00");
    });

    testWidgets("an unparseable start time doesn't crash the session screen", (tester) async {
      const broken = LiveSession(
        id: "run-1",
        trainerId: "coach-1",
        date: today,
        slotMin: ninePm,
        sessionType: "semi-private",
        startedAt: "not a timestamp",
      );
      expect(await shown(tester, broken), "0:00");
    });
  });

  group("a session ends when its time runs out", () {
    LiveSession run(Duration ago, {int durationMin = 60, String? endedAt}) => LiveSession(
          id: "run-1",
          trainerId: "coach-1",
          date: today,
          slotMin: ninePm,
          sessionType: "semi-private",
          durationMin: durationMin,
          startedAt: DateTime.now().toUtc().subtract(ago).toIso8601String(),
          endedAt: endedAt,
        );

    test("still live part-way through", () {
      expect(run(const Duration(minutes: 30)).isLive, isTrue);
      expect(run(const Duration(minutes: 30)).supportsBeep, isTrue);
    });

    test("over once the hour is up, with no write needed", () {
      // The coach's phone may be locked or out of signal when the hour
      // ends; the clients in the session must still stop being able to beep.
      final finished = run(const Duration(minutes: 61));
      expect(finished.isLive, isFalse);
      expect(finished.supportsBeep, isFalse);
    });

    test("a session that ran out is flagged for closing off", () {
      expect(run(const Duration(minutes: 61)).hasRunOut, isTrue);
    });

    test("one already ended is not flagged again", () {
      // Otherwise the coach's screen would keep trying to end it.
      expect(run(const Duration(minutes: 61), endedAt: "2026-10-10T22:00:00Z").hasRunOut, isFalse);
    });

    test("one still running is not flagged", () {
      expect(run(const Duration(minutes: 10)).hasRunOut, isFalse);
    });

    test("a short session ends at its own length, not at an hour", () {
      expect(run(const Duration(minutes: 35), durationMin: 30).isLive, isFalse);
      expect(run(const Duration(minutes: 35), durationMin: 90).isLive, isTrue);
    });

    test("ending early still ends it", () {
      expect(run(const Duration(minutes: 5), endedAt: "2026-10-10T21:05:00Z").isLive, isFalse);
    });
  });

  group("what counts as checked in", () {
    test("a coach marking someone checked-in unlocks the slot", () {
      final b = booking(attendanceStatus: "checked-in");
      expect(b.clientStartedEarly, isFalse);
      expect(bookingUnlocksSession(b), isTrue);
      expect(
        mayStart(viewDate: today, nowMin: 8 * 60 + 22, someoneCheckedIn: bookingUnlocksSession(b)),
        isTrue,
      );
    });

    test("the client starting their own session unlocks it too", () {
      final b = booking(clientStartedAt: "2026-10-10T18:00:00Z");
      expect(bookingUnlocksSession(b), isTrue);
    });

    test("an untouched booking does not", () {
      expect(bookingUnlocksSession(booking()), isFalse);
    });
  });

  group("three live sessions at once", () {
    test("a second and a third start are allowed", () {
      expect(startingAnotherLiveSessionIsBlocked(liveCount: 0, alreadyLive: false), isFalse);
      expect(startingAnotherLiveSessionIsBlocked(liveCount: 2, alreadyLive: false), isFalse);
    });

    test("a fourth start is blocked", () {
      expect(startingAnotherLiveSessionIsBlocked(liveCount: 3, alreadyLive: false), isTrue);
      expect(kLiveSessionCapMessage, contains("3 sessions"));
    });

    test("rejoining one of the three is not a new start", () {
      expect(startingAnotherLiveSessionIsBlocked(liveCount: 3, alreadyLive: true), isFalse);
    });
  });

}
