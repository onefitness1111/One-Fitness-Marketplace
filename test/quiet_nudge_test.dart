import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/quiet_nudge.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/food_log.dart";
import "package:onefitness/data/models/quiet_nudge.dart";
import "package:onefitness/data/models/workout_log.dart";

FoodLogItem egg() => const FoodLogItem(
  id: "1",
  name: "Eggs",
  qty: 2,
  unit: "eggs",
  calories: 140,
  protein: 12,
  carbs: 1,
  fats: 10,
);

// Sunday Nov 22 2026, 5:00 PM at the gym (PST, UTC-8) — same clock as
// needs_program_7day_test, so "next 7 days" matches that helper.
final now = DateTime.utc(2026, 11, 23, 1, 0);

Booking session(String id, String client, String coach, String date, int slot,
        {String status = "confirmed", String? attendance, int duration = 60}) =>
    Booking(
      id: id,
      clientId: client,
      trainerId: coach,
      date: date,
      slot: slot,
      sessionType: "1on1",
      discipline: "strength",
      status: status,
      attendanceStatus: attendance,
      durationMin: duration,
    );

QuietNudge openNudge(String clientId, {String? coachId}) => QuietNudge(
      clientId: clientId,
      lastActivityOn: "2026-11-15",
      textSentOn: "2026-11-18",
      coachId: coachId,
    );

void main() {
  final today = DateTime(2026, 11, 18);

  test("two quiet days send one phone notification", () {
    final days = quietDaysBetween(today, DateTime(2026, 11, 16));
    expect(days, 2);
    expect(
      quietNudgeStep(
        quietDays: days,
        pushAlreadySent: false,
        textAlreadySent: false,
      ),
      NudgeStep.push,
    );
  });

  test(
    "the day after that notification, still quiet, sends the text and the staff alert",
    () {
      final days = quietDaysBetween(today, DateTime(2026, 11, 15));
      expect(days, 3);
      expect(
        quietNudgeStep(
          quietDays: days,
          pushAlreadySent: true,
          textAlreadySent: false,
        ),
        NudgeStep.textAndAlert,
      );
    },
  );

  test("one quiet day does nothing, and a new log resets the streak", () {
    expect(quietDaysBetween(today, DateTime(2026, 11, 17)), 1);
    expect(
      quietNudgeStep(
        quietDays: 1,
        pushAlreadySent: true,
        textAlreadySent: true,
      ),
      NudgeStep.rest,
    );
    expect(
      quietNudgeStep(
        quietDays: 0,
        pushAlreadySent: true,
        textAlreadySent: true,
      ),
      NudgeStep.rest,
    );
  });

  test("the same streak is not nudged twice", () {
    expect(
      quietNudgeStep(
        quietDays: 2,
        pushAlreadySent: true,
        textAlreadySent: false,
      ),
      NudgeStep.none,
    );
    expect(
      quietNudgeStep(
        quietDays: 3,
        pushAlreadySent: true,
        textAlreadySent: true,
      ),
      NudgeStep.none,
    );
    expect(
      quietNudgeStep(
        quietDays: 6,
        pushAlreadySent: true,
        textAlreadySent: true,
      ),
      NudgeStep.none,
    );
  });

  test("a missed morning sends the phone notification before the text", () {
    expect(
      quietNudgeStep(
        quietDays: 3,
        pushAlreadySent: false,
        textAlreadySent: false,
      ),
      NudgeStep.push,
    );
    expect(
      quietNudgeStep(
        quietDays: 4,
        pushAlreadySent: true,
        textAlreadySent: false,
      ),
      NudgeStep.textAndAlert,
    );
  });

  test("a text needs consent, a phone number, and no opt-out", () {
    expect(
      mayTextQuietClient(
        smsOptIn: true,
        marketingOptOut: false,
        hasConsentRecord: true,
        hasPhone: true,
      ),
      isTrue,
    );
    expect(
      mayTextQuietClient(
        smsOptIn: false,
        marketingOptOut: false,
        hasConsentRecord: true,
        hasPhone: true,
      ),
      isFalse,
    );
    expect(
      mayTextQuietClient(
        smsOptIn: true,
        marketingOptOut: true,
        hasConsentRecord: true,
        hasPhone: true,
      ),
      isFalse,
    );
    expect(
      mayTextQuietClient(
        smsOptIn: true,
        marketingOptOut: false,
        hasConsentRecord: false,
        hasPhone: true,
      ),
      isFalse,
    );
    expect(
      mayTextQuietClient(
        smsOptIn: true,
        marketingOptOut: false,
        hasConsentRecord: true,
        hasPhone: false,
      ),
      isFalse,
    );
  });

  test("the in-app alert stays until the client logs again", () {
    final nudge = openNudge("client-1", coachId: "coach-1");
    final booked = [session("b1", "client-1", "coach-1", "2026-11-23", 600)];
    final quiet = ClientRecord(id: "client-1");
    final logged = ClientRecord(
      id: "client-1",
      foodLog: FoodLog(
        days: {
          "2026-11-18": {
            "breakfast": [egg()],
          },
        },
      ),
    );
    final workout = ClientRecord(
      id: "client-1",
      workoutLogs: [
        WorkoutLogEntry(
          id: "w",
          date: "2026-11-18",
          programId: "p",
          programName: "Strength",
          dayId: "d",
          dayTitle: "Day 1",
          exercises: [
            LoggedExercise(
              name: "Squat",
              sets: const [
                LoggedSet(
                  setNum: 1,
                  targetReps: 5,
                  completedReps: 5,
                  completedWeight: 135,
                  completed: true,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    final open = quietClientAttention(
      nudges: [nudge],
      records: {"client-1": quiet},
      rosterIds: {"client-1"},
      isOwner: false,
      viewerId: "coach-1",
      bookings: booked,
      now: now,
    );
    expect(open, hasLength(1));
    expect(open.first.label, "Hasn't logged lately");

    expect(
      quietClientAttention(
        nudges: [nudge],
        records: {"client-1": logged},
        rosterIds: {"client-1"},
        isOwner: true,
        viewerId: null,
        bookings: booked,
        now: now,
      ),
      isEmpty,
    );
    expect(loggedSince(workout, "2026-11-15"), isTrue);
  });

  test("a coach sees a quiet client only when booked with them in the next 7 days", () {
    // The job may have stored another coach, or none. The in-app list
    // ignores that field and uses upcoming bookings only.
    final nudge = openNudge("c1", coachId: "other-coach");
    final quiet = {"c1": ClientRecord(id: "c1")};
    final roster = {"c1"};
    final withMe = [session("b1", "c1", "k1", "2026-11-23", 600)];
    final withSomeoneElse = [session("b2", "c1", "k2", "2026-11-23", 600)];
    final cancelled = [session("b3", "c1", "k1", "2026-11-23", 600, status: "cancelled")];
    final tooFar = [session("b4", "c1", "k1", "2026-11-29", 1080)]; // 7 days + 1 hour

    items({required List<Booking> bookings, String? viewerId = "k1"}) =>
        quietClientAttention(
          nudges: [nudge],
          records: quiet,
          rosterIds: roster,
          isOwner: false,
          viewerId: viewerId,
          bookings: bookings,
          now: now,
        );

    expect(items(bookings: withMe).map((i) => i.clientId), ["c1"]);
    expect(items(bookings: withSomeoneElse), isEmpty);
    expect(items(bookings: cancelled), isEmpty);
    expect(items(bookings: tooFar), isEmpty);
    expect(items(bookings: withMe, viewerId: null), isEmpty);
  });

  test("the owner sees every quiet client; a matching coachId is not required", () {
    final nudges = [
      openNudge("c1", coachId: "k2"),
      openNudge("c2"),
    ];
    final records = {
      "c1": ClientRecord(id: "c1"),
      "c2": ClientRecord(id: "c2"),
    };
    // Only c1 is booked with k1 soon. The owner still sees both.
    final bookings = [session("b1", "c1", "k1", "2026-11-23", 600)];

    final owner = quietClientAttention(
      nudges: nudges,
      records: records,
      rosterIds: {"c1", "c2"},
      isOwner: true,
      viewerId: null,
      bookings: bookings,
      now: now,
    );
    expect(owner.map((i) => i.clientId).toSet(), {"c1", "c2"});

    final coach = quietClientAttention(
      nudges: nudges,
      records: records,
      rosterIds: {"c1", "c2"},
      isOwner: false,
      viewerId: "k1",
      bookings: bookings,
      now: now,
    );
    expect(coach.map((i) => i.clientId).toSet(), {"c1"});
  });
}
