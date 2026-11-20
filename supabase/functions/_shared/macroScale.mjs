// Scales protein, carbs, and fat grams so 4P + 4C + 9F is close to a
// calorie count the client already chose. Returns null when there is
// nothing to scale. The phone applies the same idea again and keeps any
// number the client typed.

function round1(n) {
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.round(n * 10) / 10;
}

function num(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n;
}

export function scaleMacrosToCalories(protein, carbs, fats, calories) {
  const source = [num(protein), num(carbs), num(fats)];
  const cal = Math.round(Number(calories));
  if (!Number.isFinite(cal) || cal < 0) return null;
  const from = 4 * source[0] + 4 * source[1] + 9 * source[2];
  if (from <= 0) return null;
  if (cal === 0) return { protein: 0, carbs: 0, fats: 0 };
  const scale = cal / from;
  const grams = source.map((g) => round1(g * scale));
  const adjustable = source.map((g, i) => g > 0 && grams[i] > 0);
  const gap = cal - (4 * grams[0] + 4 * grams[1] + 9 * grams[2]);
  if (Math.abs(gap) >= 0.4 && Math.abs(gap) <= 2) {
    const per = [4, 4, 9];
    for (let i = 0; i < 3; i++) {
      if (!adjustable[i]) continue;
      const next = round1(grams[i] + gap / per[i]);
      if (next <= 0) continue;
      grams[i] = next;
      break;
    }
  }
  return { protein: grams[0], carbs: grams[1], fats: grams[2] };
}
