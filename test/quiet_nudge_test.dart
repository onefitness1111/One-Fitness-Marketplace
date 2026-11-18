import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/quiet_nudge.dart";
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
    final nudge = QuietNudge(
      clientId: "client-1",
      lastActivityOn: "2026-11-15",
      textSentOn: "2026-11-18",
      coachId: "coach-1",
    );
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
      ),
      isEmpty,
    );
    expect(loggedSince(workout, "2026-11-15"), isTrue);
    expect(
      quietClientAttention(
        nudges: [nudge],
        records: {"client-1": quiet},
        rosterIds: {"client-1"},
        isOwner: false,
        viewerId: "someone-else",
      ),
      isEmpty,
    );
  });
}
