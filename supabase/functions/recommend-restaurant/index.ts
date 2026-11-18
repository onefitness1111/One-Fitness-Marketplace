// Looks up a restaurant by the name it has on Google Maps, then suggests
// items from that meal (breakfast, lunch, or dinner) that fit the slot's
// calorie and macro budget.
// Not deployed until this function is deployed.
//
// Needs the secret GOOGLE_MAPS_API_KEY (Places API, Text Search). Menu
// numbers also use the existing ANTHROPIC_API_KEY. Neither key is written
// in this file.
//
// The signed-in client (or the owner) can call it. Coaches are refused.
// The phone only ever sees "Estimate".
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

type Place = { id: string; name: string; address: string };

const SLOTS = new Set(["breakfast", "lunch", "dinner"]);

function budgetLine(body: Record<string, unknown>): string {
  const parts: string[] = [];
  const cal = Number(body.calories);
  const protein = Number(body.protein);
  const carbs = Number(body.carbs);
  const fats = Number(body.fats);
  if (Number.isFinite(cal) && cal > 0) parts.push(`at or under ${Math.round(cal)} calories`);
  if (Number.isFinite(protein) && protein > 0) parts.push(`at or under ${protein} g protein`);
  if (Number.isFinite(carbs) && carbs > 0) parts.push(`at or under ${carbs} g carbs`);
  if (Number.isFinite(fats) && fats > 0) parts.push(`at or under ${fats} g fat`);
  return parts.length ? parts.join(", ") : "a normal single serving";
}

function fits(item: { calories: number; protein: number; carbs: number; fats: number }, body: Record<string, unknown>) {
  const cal = Number(body.calories);
  const protein = Number(body.protein);
  const carbs = Number(body.carbs);
  const fats = Number(body.fats);
  if (item.calories <= 0) return false;
  if (Number.isFinite(cal) && cal > 0 && item.calories > cal) return false;
  if (Number.isFinite(protein) && protein > 0 && item.protein > protein + 0.5) return false;
  if (Number.isFinite(carbs) && carbs > 0 && item.carbs > carbs + 0.5) return false;
  if (Number.isFinite(fats) && fats > 0 && item.fats > fats + 0.5) return false;
  return true;
}

async function searchPlaces(query: string): Promise<Place[]> {
  const key = (Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "").trim();
  if (!key) {
    throw new Error("Restaurant search isn't set up yet.");
  }
  const res = await fetch("https://places.googleapis.com/v1/places:searchText", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": key,
      "X-Goog-FieldMask": "places.id,places.displayName,places.formattedAddress",
    },
    body: JSON.stringify({
      textQuery: query,
      includedType: "restaurant",
      pageSize: 5,
    }),
  });
  if (!res.ok) {
    console.error("places status", res.status);
    throw new Error("Couldn't search restaurants. Try again.");
  }
  const data = await res.json();
  const places = Array.isArray(data.places) ? data.places : [];
  return places.map((p: { id?: string; displayName?: { text?: string }; formattedAddress?: string }) => ({
    id: String(p.id ?? ""),
    name: scrub(p.displayName?.text, 80),
    address: scrub(p.formattedAddress, 120),
  })).filter((p: Place) => p.name);
}

async function suggestItems(place: Place, slot: string, body: Record<string, unknown>) {
  const text = await askModel({
    model: "claude-opus-5",
    max_tokens: 900,
    system:
      "You suggest dishes from a restaurant's menu for one meal. Reply with JSON only: " +
      "{\"items\":[{\"name\":\"\",\"calories\":0,\"protein\":0,\"carbs\":0,\"fats\":0}]}. " +
      "Use items that restaurant is known to serve at that meal. " +
      "calories is a whole number for one typical serving. protein, carbs, and fats are grams. " +
      "Stay at or under the limits you are given. Give 4 to 6 items. No other words.",
    messages: [{
      role: "user",
      content: `Restaurant: ${place.name}${place.address ? `, ${place.address}` : ""}\nMeal: ${slot}\nEach item must be ${budgetLine(body)}.`,
    }],
  });
  const parsed = parseModelJson(text);
  const raw = Array.isArray(parsed.items) ? parsed.items : [];
  return raw.map((item) => {
    const row = item as Record<string, unknown>;
    return {
      name: scrub(row.name, 70),
      calories: Math.round(clamp(row.calories, 2500)),
      protein: clamp(row.protein, 250),
      carbs: clamp(row.carbs, 300),
      fats: clamp(row.fats, 200),
      label: "Estimate",
    };
  }).filter((item) => item.name && fits(item, body)).slice(0, 6);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    await requireClientOrOwner(req);
    const body = await req.json() as Record<string, unknown>;
    const slot = String(body.slot ?? "");
    if (!SLOTS.has(slot)) throw new Error("Choose breakfast, lunch, or dinner.");

    const named = scrub(body.placeName, 80);
    if (named) {
      const place: Place = {
        id: scrub(body.placeId, 120),
        name: named,
        address: scrub(body.address, 120),
      };
      const items = await suggestItems(place, slot, body);
      return json({ ok: true, places: [place], picked: place, items });
    }

    const query = scrub(body.query, 80);
    if (query.length < 2) throw new Error("Type the restaurant's name.");
    const places = await searchPlaces(query);
    if (places.length === 0) {
      return json({ ok: true, places: [], items: [] });
    }
    if (places.length > 1) {
      return json({ ok: true, places, items: [] });
    }
    const items = await suggestItems(places[0], slot, body);
    return json({ ok: true, places, picked: places[0], items });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Couldn't search right now.";
    return json({ ok: false, error: scrub(message, 180) || "Couldn't search right now." }, 400);
  }
});
