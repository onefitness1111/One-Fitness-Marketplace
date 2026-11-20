// Estimates a plate from a photo, or protein, carbs, and fat from a food
// name plus a calorie count (no photo).
// Not live until this function is deployed again.
//
// The signed-in client (or the owner) can call it. Coaches are refused.
// Gateway verify_jwt is true. The phone only ever sees "Estimate".
// This response does not say how the numbers were produced.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { scaleMacrosToCalories } from "../_shared/macroScale.mjs";
import {
  CORS_HEADERS,
  askModel,
  clamp,
  json,
  parseModelJson,
  requireClientOrOwner,
  scrub,
} from "../_shared/estimateAuth.ts";

function imageData(body: Record<string, unknown>): string {
  let image = String(body.image ?? "").trim();
  const comma = image.indexOf(",");
  if (image.startsWith("data:") && comma > 0) image = image.slice(comma + 1);
  return image.replace(/\s/g, "");
}

async function estimatePhoto(image: string) {
  const text = await askModel({
    model: "claude-opus-5",
    max_tokens: 400,
    system:
      "You estimate a plate of food. Reply with JSON only: " +
      "{\"name\":\"short food name\",\"calories\":0,\"protein\":0,\"carbs\":0,\"fats\":0}. " +
      "Numbers are for the whole plate in the photo. calories is a whole number. " +
      "protein, carbs, and fats are grams. If you are unsure, give a cautious middle estimate. " +
      "No other words.",
    messages: [{
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: "image/jpeg", data: image } },
        { type: "text", text: "Estimate this plate." },
      ],
    }],
  });
  const parsed = parseModelJson(text);
  const name = scrub(parsed.name, 60) || "Plate";
  return {
    ok: true,
    name,
    calories: Math.round(clamp(parsed.calories, 4000)),
    protein: clamp(parsed.protein, 300),
    carbs: clamp(parsed.carbs, 400),
    fats: clamp(parsed.fats, 250),
    label: "Estimate",
  };
}

async function estimateNamedFood(body: Record<string, unknown>) {
  const name = scrub(body.name, 80);
  const calories = Number(body.calories);
  if (!name || !Number.isFinite(calories) || calories < 0 || calories > 20000) {
    throw new Error("Type a food name and the calories.");
  }
  const cal = Math.round(calories);
  if (cal === 0) {
    return { ok: true, name, calories: 0, protein: 0, carbs: 0, fats: 0, label: "Estimate" };
  }
  const text = await askModel({
    model: "claude-opus-5",
    max_tokens: 200,
    system:
      "You estimate protein, carbs, and fat for one food. Reply with JSON only: " +
      "{\"protein\":0,\"carbs\":0,\"fats\":0}. " +
      "The calorie count is already chosen and must not be changed. " +
      "protein, carbs, and fats are grams for that many calories. " +
      "4*protein + 4*carbs + 9*fats should be close to the calorie count. " +
      "If you are unsure, give a cautious middle estimate. No other words.",
    messages: [{
      role: "user",
      content: `Food: ${name}\nCalories: ${cal}`,
    }],
  });
  const parsed = parseModelJson(text);
  const scaled = scaleMacrosToCalories(
    clamp(parsed.protein, 2000),
    clamp(parsed.carbs, 2000),
    clamp(parsed.fats, 2000),
    cal,
  );
  if (!scaled) throw new Error("Couldn't make an estimate. Try again.");
  return {
    ok: true,
    name,
    calories: cal,
    protein: scaled.protein,
    carbs: scaled.carbs,
    fats: scaled.fats,
    label: "Estimate",
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    await requireClientOrOwner(req);
    const raw = await req.json();
    const body = raw && typeof raw === "object" && !Array.isArray(raw)
      ? raw as Record<string, unknown>
      : {};
    const image = imageData(body);
    if (image.length > 0) {
      if (image.length < 100 || image.length > 1_800_000) {
        throw new Error("That photo couldn't be read. Try another one.");
      }
      return json(await estimatePhoto(image));
    }
    return json(await estimateNamedFood(body));
  } catch (e) {
    const message = e instanceof Error ? e.message : "Couldn't make an estimate. Try again.";
    return json({ ok: false, error: scrub(message, 180) || "Couldn't make an estimate. Try again." }, 400);
  }
});
