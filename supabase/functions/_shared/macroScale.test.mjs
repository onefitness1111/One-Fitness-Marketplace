import assert from "node:assert/strict";
import test from "node:test";
import { scaleMacrosToCalories } from "./macroScale.mjs";

function kcal(m) {
  return 4 * m.protein + 4 * m.carbs + 9 * m.fats;
}

test("a zero source cannot be scaled", () => {
  assert.equal(scaleMacrosToCalories(0, 0, 0, 400), null);
  assert.equal(scaleMacrosToCalories(-1, "nope", null, 400), null);
});

test("zero calories becomes zero grams", () => {
  assert.deepEqual(scaleMacrosToCalories(10, 20, 5, 0), { protein: 0, carbs: 0, fats: 0 });
});

test("grams are scaled to the given calories", () => {
  const scaled = scaleMacrosToCalories(10, 20, 5, 400);
  assert.ok(scaled);
  assert.ok(Math.abs(kcal(scaled) - 400) <= 1.5);
  assert.ok(scaled.carbs > scaled.protein);
  assert.ok(scaled.protein > 0);
  assert.ok(scaled.fats > 0);
});

test("a fat-only food stays fat", () => {
  const scaled = scaleMacrosToCalories(0, 0, 13.5, 119);
  assert.ok(scaled);
  assert.equal(scaled.protein, 0);
  assert.equal(scaled.carbs, 0);
  assert.ok(scaled.fats > 0);
  assert.ok(Math.abs(kcal(scaled) - 119) <= 1.5);
});
