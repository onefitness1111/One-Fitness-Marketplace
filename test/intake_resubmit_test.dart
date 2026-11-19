import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/utils/intake_resubmit.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/intake_schema.dart";

void main() {
  IntakeRecord filing(String goal, {bool completed = true, String at = "2026-01-01", List<IntakeSubmission> history = const []}) =>
      IntakeRecord(
        answers: {"primaryGoal": goal},
        completed: completed,
        at: at,
        by: "Client",
        history: history,
      );

  test("a new filing archives the completed one and keeps the new answers current", () {
    final next = archiveOnResubmit(
      filing("Fat Loss", at: "2026-01-01"),
      filing("Strength", at: "2026-11-19"),
    );
    expect(next.answers["primaryGoal"], "Strength");
    expect(next.history, hasLength(1));
    expect(next.history.first.answers["primaryGoal"], "Fat Loss");
    expect(next.history.first.archivedAt, "2026-11-19");
    expect(intakeAnswersForAi(next)["primaryGoal"], "Strength");
  });

  test("an unfinished draft is replaced, not archived", () {
    final next = archiveOnResubmit(
      filing("Fat Loss", completed: false),
      filing("Strength", at: "2026-11-19"),
    );
    expect(next.history, isEmpty);
    expect(next.answers["primaryGoal"], "Strength");
  });

  test("program generation ignores archived filings", () {
    final current = filing("Strength", at: "2026-11-19", history: [
      IntakeSubmission(answers: {"primaryGoal": "Fat Loss"}, at: "2026-01-01", archivedAt: "2026-11-19"),
    ]);
    expect(intakeAnswersForAi(current)["primaryGoal"], "Strength");
    expect(
      primarySubmission([
        IntakeSubmission(answers: {"primaryGoal": "Fat Loss"}, at: "2026-01-01", archivedAt: "2026-06-01"),
        IntakeSubmission(answers: {"primaryGoal": "Strength"}, at: "2026-11-19"),
      ])?.answers["primaryGoal"],
      "Strength",
    );
  });

  test("training and nutrition intakes ask for the matching program", () {
    expect(programRefreshKind("personalTraining"), "training");
    expect(programRefreshKind("physical"), "training");
    expect(programRefreshKind("nutritional"), "nutrition");
    expect(shouldFlagProgramRefresh(keepPrevious: true, alreadyCompleted: true), isTrue);
    expect(shouldFlagProgramRefresh(keepPrevious: false, alreadyCompleted: true), isFalse);
    expect(programRefreshLabel("training", forOwner: true), "New training program needed");
    expect(programRefreshLabel("nutrition", forOwner: true), "New nutrition program needed");
    expect(programRefreshLabel("training", forOwner: false), "Program update pending");
  });

  test("the journey lists the current filing and the archived one", () {
    final lines = intakeJourneyLines(
      {
        "personalTraining": filing("Strength", at: "2026-11-19", history: [
          IntakeSubmission(answers: {"primaryGoal": "Fat Loss"}, at: "2026-01-01", by: "Client", archivedAt: "2026-11-19"),
        ]),
      },
      (key) => key == "personalTraining" ? "Personalized Training Intake" : key,
    );
    expect(lines.map((line) => line.title).toList(), [
      "Updated Personalized Training Intake",
      "Updated Personalized Training Intake",
    ]);
    expect(lines.first.at, "2026-11-19");
    expect(lines.last.archived, isTrue);
  });

  test("the owner dashboard names the program and a coach does not", () {
    const client = ClientInfo(id: "c1", name: "Jordan");
    final records = {
      "c1": ClientRecord(id: "c1", programRefresh: {"training": "2026-11-19"}),
    };
    expect(
      programRefreshAttention([client], records, forOwner: true).single.label,
      "New training program needed",
    );
    expect(
      programRefreshAttention([client], records, forOwner: false).single.label,
      "Program update pending",
    );
  });
}
