// Estimates calories and macros from a photo of a plate.
// Not deployed until this function is deployed.
//
// The signed-in client (or the owner) can call it. Coaches are refused.
// The phone only ever sees "Estimate". This response does not say how the
// numbers were produced.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import {
  CORS_HEADERS,
  askModel,
  clamp,
  json,
  parseModelJson,
  requireClientOrOwner,
  scrub,
} from "../_shared/estimateAuth.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    await requireClientOrOwner(req);
    const body = await req.json();
    let image = String(body.image ?? "").trim();
    const comma = image.indexOf(",");
    if (image.startsWith("data:") && comma > 0) image = image.slice(comma + 1);
    image = image.replace(/\s/g, "");
    if (image.length < 100 || image.length > 1_800_000) {
      throw new Error("That photo couldn't be read. Try another one.");
    }

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
    return json({
      ok: true,
      name,
      calories: Math.round(clamp(parsed.calories, 4000)),
      protein: clamp(parsed.protein, 300),
      carbs: clamp(parsed.carbs, 400),
      fats: clamp(parsed.fats, 250),
      label: "Estimate",
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Couldn't make an estimate. Try again.";
    return json({ ok: false, error: scrub(message, 180) || "Couldn't make an estimate. Try again." }, 400);
  }
});
