import assert from "node:assert/strict";
import test from "node:test";
import { currentIntake, primarySubmission } from "./currentIntake.mjs";

test("program generation reads the current answers, not an archived filing", () => {
  const intake = currentIntake({
    intake: {
      personalTraining: {
        completed: true,
        answers: { primaryGoal: ["Strength"] },
        history: [{ answers: { primaryGoal: ["Fat Loss"] }, at: "2026-01-01" }],
      },
      nutritional: {
        archivedAt: "2026-06-01",
        completed: true,
        answers: { goal: "old" },
      },
    },
  });
  assert.deepEqual(intake.personalTraining.answers, { primaryGoal: ["Strength"] });
  assert.equal(intake.personalTraining.history, undefined);
  assert.equal(intake.nutritional, undefined);
});

test("the newest open submission is the primary one", () => {
  const picked = primarySubmission([
    { assessment_key: "personalTraining", answers: { n: 1 }, archived_at: "2026-02-01", created_at: "2026-01-01" },
    { assessment_key: "personalTraining", answers: { n: 2 }, archived_at: null, created_at: "2026-03-01" },
    { assessment_key: "personalTraining", answers: { n: 3 }, created_at: "2026-04-02" },
  ]);
  assert.equal(picked.answers.n, 3);
});
