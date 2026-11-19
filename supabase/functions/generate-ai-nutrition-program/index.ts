// Drafts calorie and macro targets. Proposed replacement — not deployed
// until you deploy this function.
//
// The only behavior change from the live function: only the owner can start
// it. A client finishing an intake form, and a coach, are refused. Coaches
// can still approve a draft that already exists. The draft shape written
// into client_records is unchanged.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildAttachmentBlocks } from "../_shared/intakeAttachments.ts";
import { intakeForAi } from "../_shared/currentIntake.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function uid() {
  return Math.random().toString(36).slice(2, 10);
}
function stamp() {
  return new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

const MEAL_BUDGET_SCHEMA = {
  type: "object",
  properties: {
    breakfast: { type: "string" },
    lunch: { type: "string" },
    dinner: { type: "string" },
    snacks: { type: "string" },
  },
  required: ["breakfast", "lunch", "dinner", "snacks"],
  additionalProperties: false,
};

const DAY_TARGET_SCHEMA = {
  type: "object",
  properties: {
    calories: { type: "string" },
    protein: { type: "string" },
    carbs: { type: "string" },
    fats: { type: "string" },
    water: { type: "string" },
    mealBudgets: MEAL_BUDGET_SCHEMA,
  },
  required: ["calories", "protein", "carbs", "fats", "water", "mealBudgets"],
  additionalProperties: false,
};

const NUTRITION_SCHEMA = {
  type: "object",
  properties: {
    training: DAY_TARGET_SCHEMA,
    rest: DAY_TARGET_SCHEMA,
    notes: { type: "string" },
  },
  required: ["training", "rest", "notes"],
  additionalProperties: false,
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId, forceRegenerate } = await req.json();
    if (!clientId) throw new Error("clientId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "owner") {
      throw new Error("Only the owner can generate a program.");
    }

    const { data: clientProfile } = await admin.from("profiles").select("name").eq("id", clientId).maybeSingle();
    const clientName = clientProfile?.name || "Client";

    const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
    const record = recordRow?.data || {};
    const intake = await intakeForAi(admin, clientId, record);
    if (!intake.nutritional?.completed) {
      return new Response(JSON.stringify({ ok: false, reason: "nutrition-intake-incomplete" }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    // deno-lint-ignore no-explicit-any
    const savedNutritionPrograms = record.savedNutritionPrograms || [];
    // deno-lint-ignore no-explicit-any
    const hasAiNutritionProgram = savedNutritionPrograms.some((p: any) => p.type === "nutrition" && p.source === "ai");
    if (hasAiNutritionProgram && !forceRegenerate) {
      return new Response(JSON.stringify({ ok: false, reason: "program-exists" }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    const extraContext: string[] = [];
    if (intake.personalTraining?.completed) {
      extraContext.push(`Personal Training Intake answers:\n${JSON.stringify(intake.personalTraining.answers || {}, null, 2)}`);
    }
    if (intake.physical?.completed) {
      extraContext.push(`Physical Assessment notes: ${JSON.stringify(intake.physical.overall || {})}`);
    }

    const attachments = await buildAttachmentBlocks(admin, record, ["nutritional"]);
    const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim(),
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-opus-5",
        max_tokens: 4000,
        thinking: { type: "adaptive" },
        system:
          "You are an expert sports nutrition coach setting a client's FIRST calorie and macro targets from their intake answers. " +
          "Use Mifflin-St Jeor, then adjust for their goal. Never prescribe an extreme deficit or surplus: cap a deficit near 20-25% below maintenance and a surplus near 10-20% above it. If the answers look unsafe, set moderate targets and say so in notes. " +
          "Produce training and rest day targets. protein, carbs, and fats are percents of calories and must sum to 100. water is liters, a whole number. mealBudgets are whole-number kcal for breakfast, lunch, dinner, and snacks and must sum to the day's calories. " +
          "Every number is a single plain integer as a string. notes are a few plain sentences for the coach, mentioning allergies and the goal. No markdown.",
        messages: [{
          role: "user",
          content: [
            ...attachments.blocks,
            {
              type: "text",
              text:
                `Nutrition Intake answers:\n${JSON.stringify(intake.nutritional.answers || {}, null, 2)}` +
                (extraContext.length ? `\n\n${extraContext.join("\n\n")}` : ""),
            },
          ],
        }],
        output_config: { format: { type: "json_schema", schema: NUTRITION_SCHEMA } },
      }),
    });
    if (!anthropicRes.ok) {
      const errBody = await anthropicRes.text();
      console.error(`anthropic ${anthropicRes.status}: ${errBody}`);
      if (anthropicRes.status === 401 || anthropicRes.status === 403) {
        throw new Error("AI drafting isn't set up right now — the Anthropic API key is missing or no longer valid. Ask your administrator to update ANTHROPIC_API_KEY.");
      }
      if (anthropicRes.status === 429) throw new Error("The AI service is busy right now. Wait a minute and try again.");
      if (errBody.includes("credit_balance_too_low")) {
        throw new Error("The Anthropic account is out of credit. Ask your administrator to top it up.");
      }
      throw new Error(`Couldn't draft these targets (${anthropicRes.status}). Please try again.`);
    }
    const message = await anthropicRes.json();
    if (message.stop_reason === "refusal") throw new Error("Claude declined to draft these targets.");
    // deno-lint-ignore no-explicit-any
    const textBlock = (message.content || []).find((b: any) => b.type === "text");
    if (!textBlock) throw new Error("Claude returned no draft content.");
    const parsed = JSON.parse(textBlock.text);

    // deno-lint-ignore no-explicit-any
    function sanitizeNumericField(value: any): string {
      if (value == null) return "";
      const match = String(value).match(/\d+/);
      return match ? match[0] : "";
    }
    function normalizeMacroPercents(p: number, c: number, f: number) {
      const sum = p + c + f;
      if (!sum) return { protein: 34, carbs: 33, fats: 33 };
      const protein = Math.round((p / sum) * 100);
      const carbs = Math.round((c / sum) * 100);
      let fats = 100 - protein - carbs;
      if (fats < 0) fats = 0;
      return { protein, carbs, fats };
    }
    function normalizeMealBudgets(calories: number, b: number, l: number, d: number, s: number) {
      const keys = ["breakfast", "lunch", "dinner", "snacks"] as const;
      const raw: Record<string, number> = { breakfast: b, lunch: l, dinner: d, snacks: s };
      const sum = b + l + d + s;
      const out: Record<string, string> = {};
      if (!calories) return { breakfast: "0", lunch: "0", dinner: "0", snacks: "0" };
      let used = 0;
      keys.forEach((k, i) => {
        const v = i === keys.length - 1 ? calories - used : Math.round(sum ? (raw[k] / sum) * calories : calories * [0.25, 0.3, 0.3, 0.15][i]);
        out[k] = String(v);
        used += v;
      });
      return out;
    }
    // deno-lint-ignore no-explicit-any
    function sanitizeDayTarget(t: any) {
      const { protein, carbs, fats } = normalizeMacroPercents(
        Number(sanitizeNumericField(t?.protein)) || 0,
        Number(sanitizeNumericField(t?.carbs)) || 0,
        Number(sanitizeNumericField(t?.fats)) || 0,
      );
      const calories = sanitizeNumericField(t?.calories);
      return {
        calories,
        protein: String(protein),
        carbs: String(carbs),
        fats: String(fats),
        water: sanitizeNumericField(t?.water),
        mealBudgets: normalizeMealBudgets(
          Number(calories) || 0,
          Number(sanitizeNumericField(t?.mealBudgets?.breakfast)) || 0,
          Number(sanitizeNumericField(t?.mealBudgets?.lunch)) || 0,
          Number(sanitizeNumericField(t?.mealBudgets?.dinner)) || 0,
          Number(sanitizeNumericField(t?.mealBudgets?.snacks)) || 0,
        ),
      };
    }

    const trainingFull = sanitizeDayTarget(parsed.training);
    const restFull = sanitizeDayTarget(parsed.rest);
    const targets = {
      training: { calories: trainingFull.calories, protein: trainingFull.protein, carbs: trainingFull.carbs, fats: trainingFull.fats, water: trainingFull.water },
      rest: { calories: restFull.calories, protein: restFull.protein, carbs: restFull.carbs, fats: restFull.fats, water: restFull.water },
    };
    if (!targets.training.calories || !targets.rest.calories) throw new Error("Claude's draft was missing calorie targets. Try regenerating.");
    const MIN_SAFE_CALORIES = 1200;
    if (Number(targets.training.calories) < MIN_SAFE_CALORIES || Number(targets.rest.calories) < MIN_SAFE_CALORIES) {
      throw new Error(`Claude's draft set a calorie target below the ${MIN_SAFE_CALORIES} kcal safety floor. Not saved.`);
    }
    const mealBudgets = { training: trainingFull.mealBudgets, rest: restFull.mealBudgets };
    const guidelines = typeof parsed.notes === "string" ? parsed.notes.trim() : "";

    const entry = {
      id: uid(),
      name: `${clientName} - Nutrition`,
      type: "nutrition",
      status: "draft",
      source: "ai",
      createdAt: stamp(),
      createdBy: "AI (draft)",
      modifiedAt: stamp(),
      assignedClientId: clientId,
      assignedClientName: clientName,
      targets,
      mealBudgets,
      guidelines,
    };

    const nextPrograms = forceRegenerate
      // deno-lint-ignore no-explicit-any
      ? [...savedNutritionPrograms.filter((p: any) => !(p.type === "nutrition" && p.source === "ai" && p.status === "draft")), entry]
      : [...savedNutritionPrograms, entry];

    const { error: upsertErr } = await admin.from("client_records")
      .upsert({ profile_id: clientId, data: { ...record, savedNutritionPrograms: nextPrograms } });
    if (upsertErr) throw upsertErr;

    return new Response(JSON.stringify({ ok: true, programId: entry.id }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("generate-ai-nutrition-program failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
