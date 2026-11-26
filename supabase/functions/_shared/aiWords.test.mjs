import assert from "node:assert/strict";
import test from "node:test";
import { clientSafeMessage, mentionsAi, stripAiWords } from "./aiWords.mjs";

test("C9: names and words that only contain 'ai' are not AI", () => {
  for (const ok of ["Aiden", "Craig", "again", "email", "failed", "MAIN", "EMAIL", "Thai curry", "Kai", "rain", "Mai Tai"]) {
    assert.equal(mentionsAi(ok), false, ok);
  }
});

test("C9: the word AI and AI product names are", () => {
  for (const bad of ["AI", "ai", "An AI estimate", "AI-generated", "(AI)", "A.I. draft", "OpenAI", "GenAI", "ChatGPT", "GPT-4o", "LLM", "Anthropic", "artificial intelligence", "AIs"]) {
    assert.equal(mentionsAi(bad), true, bad);
  }
});

test("L1: a client message that mentions AI becomes the fallback", () => {
  assert.equal(clientSafeMessage("The AI service failed", "Try again."), "Try again.");
  assert.equal(clientSafeMessage("That photo couldn't be read. Try another one.", "Try again."), "That photo couldn't be read. Try another one.");
  assert.equal(clientSafeMessage("", "Try again."), "Try again.");
});

test("labels lose AI words but keep real names", () => {
  assert.equal(mentionsAi(stripAiWords("Chicken bowl (AI estimate)")), false);
  assert.equal(stripAiWords("Chicken bowl (AI)"), "Chicken bowl");
  assert.equal(stripAiWords("Thai curry"), "Thai curry");
  assert.equal(stripAiWords("Craig's salad"), "Craig's salad");
});
