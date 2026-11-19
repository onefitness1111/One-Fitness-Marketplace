// Proposed replacement. Not deployed until you deploy this function.
// Only the owner can start generation. The rest of this file is the live function.
// Drafts a client's first workout program with Claude once both intake
// forms (Personal Training + Physical Assessment) are complete. Called
// fire-and-forget from IntakeArea.jsx's saveAssessment the moment the
// second of the two completes. The result is NEVER visible to the client
// directly — it's written into client_records.data.savedPrograms as
// { source: "ai", status: "draft" }, which trg_prevent_client_ai_draft_self_approve
// (schema_phase19_ai_draft_lock.sql) stops a client from ever flipping to
// "active" themselves, and which every existing client-facing program view
// already filters out (they all read `.filter(p => p.status === "active")").
// A coach/owner must review it in ProgramsPanel and hit "Approve & Assign"
// before a client ever sees it.
// Calls the Messages API via raw HTTP rather than @anthropic-ai/sdk — the
// SDK (and its zod dependency) pull in a Node stream shim through esm.sh
// that Supabase's edge bundler can't resolve at deploy time ("failed to
// load 'https://deno.land/std@0.177.1/node/stream/promises.ts'"). Raw HTTP
// has zero external deps beyond supabase-js (already proven to deploy
// cleanly via every other function in this project) and is itself an
// officially documented way to call structured outputs — see "Raw Schema"
// in the Claude API docs: output_config.format guarantees the first
// content block is type:"text" containing valid JSON matching the schema.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { committedDayCount, decideSuggestedDays } from "./suggested_days.ts";
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

// Mirrors ProgramBuilder.jsx's exercise-row shape (addExercise, line ~45) —
// exerciseId is the only field Claude must get right; everything else is a
// free-text prescription value the coach can edit after the fact.
const PROGRAM_SCHEMA = {
  type: "object",
  properties: {
    programNote: {
      type: "string",
      description: "Optional. ONLY include this if the client's stated training days/week genuinely couldn't support training every muscle group at least 2x/week, forcing you to prioritize the focus muscle group(s) instead — briefly explain that tradeoff in 1-2 sentences. Omit this field entirely (do not include it at all) when no such tradeoff was needed.",
    },
    days: {
      type: "array",
      description: "The committed training days (matching the client's stated weekly availability) followed by the suggested active days, in that order.",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          kind: {
            type: "string",
            enum: ["committed", "suggested"],
            description: "'committed' for the client's gym/strength days — the ones they signed up for. 'suggested' for an optional movement/conditioning day. The exact number of each is dictated in the user message; never produce a different count.",
          },
          rationale: {
            type: "string",
            description: "Required on a 'suggested' day, omitted on a 'committed' one: one short sentence saying why THIS day earns a place for THIS client's goal (e.g. 'Builds the aerobic base her HYROX run legs depend on'). Not a description of the workout.",
          },
          exercises: {
            type: "array",
            description: "On a COMMITTED day: a FULL, ~60-MINUTE session's worth of DIFFERENT exercises (5-8 typical) — never just one, and never the same exerciseId twice in the same day. Include a mix appropriate to the day's focus: a primary compound lift, secondary/accessory movements, and isolation or core/conditioning work. On a SUGGESTED day: 1-4 exercises only, and 30-45 minutes total, not 60 — a single steady walk or run is a complete and often ideal suggested day.",
            items: {
              type: "object",
              properties: {
                exerciseId: { type: "string", description: "Must be an id from the supplied exercise catalog — never invent one. Must be a DIFFERENT id from every other exercise in this same day — never repeat one." },
                sets: { type: "string", description: "A single plain integer only, e.g. '3'. Never a range ('3-4'), never units or words." },
                reps: { type: "string", description: "A single plain integer only, e.g. '10'. Never a range ('8-10'), never units or words like 'reps' or 'to failure'." },
                time: { type: "string", description: "A single plain number immediately followed by exactly one unit letter: 's' for seconds or 'm' for minutes — e.g. '30s' for a 30-second plank hold, '45s' for a sprint interval, '5m' for a 5-minute steady-state cardio piece. Never a range, never a space, never any other unit." },
                distance: { type: "string", description: "A single plain integer only, e.g. '400'. Never a range or units." },
                rest: { type: "string", description: "A single plain number immediately followed by exactly one unit letter: 's' for seconds or 'm' for minutes — e.g. '60s' for a 60-second rest between accessory sets, '90s' or '2m' for a heavier compound set. NEVER more than 2 minutes ('2m') — 2 minutes is the hard maximum for any rest interval, no exceptions. Never a range, never a space, never any other unit." },
                notes: { type: "string" },
                laterality: { type: "string", enum: ["bilateral", "unilateral", "alternating"] },
                supersetGroup: { type: "string", description: "Optional. Give two or more CONSECUTIVE exercises in this same day the exact same supersetGroup label (e.g. 'A') to pair them as a superset/triset. Omit for a standalone exercise." },
              },
              required: ["exerciseId"],
              additionalProperties: false,
            },
          },
        },
        required: ["title", "exercises", "kind"],
        additionalProperties: false,
      },
    },
  },
  required: ["days"],
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
    // Only the owner may start a draft. Coaches can still review and approve
    // one that already exists; a client cannot generate one.
    if (callerProfile?.role !== "owner") {
      throw new Error("Only the owner can generate a program.");
    }

    const { data: clientProfile } = await admin.from("profiles").select("name").eq("id", clientId).maybeSingle();
    const clientName = clientProfile?.name || "Client";

    const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
    const record = recordRow?.data || {};
    const intake = await intakeForAi(admin, clientId, record);
    const hasTraining = !!intake.personalTraining?.completed;
    const hasPhysical = !!intake.physical?.completed;
    // Personalized Training Intake alone gates generation — Physical
    // Assessment is never required, it's only folded into the prompt below
    // as extra context when it happens to already be done.
    if (!hasTraining) {
      return new Response(JSON.stringify({ ok: false, reason: "intakes-incomplete" }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const savedPrograms = record.savedPrograms || [];
    const hasWorkoutProgram = savedPrograms.some((p: any) => p.type === "workout");
    if (hasWorkoutProgram && !forceRegenerate) {
      return new Response(JSON.stringify({ ok: false, reason: "program-exists" }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const { data: exerciseRows } = await admin.from("exercises").select("id, data");
    const exerciseMap = new Map<string, any>();
    (exerciseRows || []).forEach((row: any) => exerciseMap.set(row.id, row.data || {}));
    const catalog = Array.from(exerciseMap.entries()).map(([id, ex]) => ({
      id, name: ex.name, primaryMuscle: ex.primaryMuscle, movementPattern: ex.movementPattern,
      equipmentIds: ex.equipmentIds, unilateral: !!ex.unilateral,
    }));
    if (!catalog.length) throw new Error("No exercises in the catalog yet — add some before generating an AI draft.");
    // A full, non-repeating ~60-minute day needs at least 5 distinct
    // exercises to draw from. Below that, no amount of prompting can
    // produce a fuller session — Claude can only pick from what's
    // actually in the catalog — so fail with the real, actionable cause
    // up front instead of a generic "day was too short" error after a
    // wasted API call.
    if (catalog.length < 5) throw new Error(`Only ${catalog.length} exercise(s) in the catalog — add at least 5 (ideally 15-20+ across different muscle groups) in the Exercises tab before generating an AI draft, so a full non-repeating session is actually possible.`);

    // The committed count comes from the intake, same as it always has; the
    // suggested count is derived from it. Both are settled before the request
    // so Claude is told numbers rather than asked to work them out.
    const trainingAnswers = (hasTraining ? intake.personalTraining.answers : null) || {};
    const requestedDays = Number(String(trainingAnswers.daysPerWeek ?? "").match(/\d+/)?.[0] ?? NaN);
    const committedDays = committedDayCount(trainingAnswers.daysPerWeek);
    // Say so rather than silently overruling what they asked for.
    const restDayNote = Number.isFinite(requestedDays) && committedDays < requestedDays
      ? `The intake asked for ${requestedDays} training days a week. This program has ${committedDays}, because every week keeps at least one full rest day.`
      : null;
    const { allowed: suggestedCount, reasons: suggestedReasons } = decideSuggestedDays(trainingAnswers, committedDays);

    // Whatever the client attached to either questionnaire, read as native
    // content blocks — so Claude sees the actual bloodwork or physio letter
    // rather than a note that one exists. Never throws: a file that has gone
    // missing costs that attachment, not the whole draft.
    const attachments = await buildAttachmentBlocks(admin, record, ["personalTraining", "nutritional"]);
    if (attachments.skipped.length) {
      console.warn(`attachments skipped: ${attachments.skipped.join("; ")}`);
    }

    const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // Trimmed: a key pasted into `supabase secrets set` with a trailing
        // space or newline is stored verbatim and rejected as invalid, which
        // looks identical to a revoked key.
        "x-api-key": (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim(),
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-opus-5",
        max_tokens: 12000,
        thinking: { type: "adaptive" },
        system: "You are an expert personal trainer building a client's first COMPLETE workout program from their intake answers. " +
          "A program has TWO kinds of day. COMMITTED days are the client's gym/strength sessions — the days they have committed to. SUGGESTED days are optional movement and conditioning days shown alongside them, so the client can see what reaching their goal actually takes without it changing what they signed up for. " +
          "THE NUMBER OF EACH IS DECIDED FOR YOU and given in the user message. Produce exactly that many committed days and exactly that many suggested days — not one more, not one fewer. Do not reason about how many are appropriate; that has already been worked out from this client's goal, experience, sleep, injuries and the intensity of their committed block. Your job is what goes IN them. " +
          "List every committed day first, then every suggested day. " +
          "PLAN THE WEEKLY SPLIT FIRST, BEFORE PICKING ANY EXERCISES: decide which muscle groups/movement patterns each day trains, choosing whichever split (full body, upper/lower, push/pull/legs, etc.) realistically fits the stated days/week. Every major muscle group trained in this program MUST be hit at MINIMUM 2x across the week — e.g. a full-body split naturally satisfies this every session; an upper/lower or push/pull/legs split must repeat within the week (Upper/Lower/Upper/Lower, or two full PPL rotations for 6 days) rather than a single pass through each pattern. " +
          "If the intake specifies a focus/priority muscle group or area, that group must ALSO hit at least 2x/week AND get extra emphasis versus other muscle groups that week — via more total sets, earlier placement in the session (trained first while fresh), or a dedicated exercise block, whichever fits the chosen split best. If the stated days/week genuinely cannot support 2x/week for every muscle group, prioritize the focus muscle group(s) first (or, if none was stated, the muscle groups most relevant to the client's primary goal) and briefly explain that tradeoff in the top-level 'programNote' field — see its schema description; omit that field entirely otherwise. " +
          "EVERY day is a FULL, FIXED 60-MINUTE session — the TOTAL programmed time (every set's work time, PLUS every rest/break interval, PLUS any cardio work) must fit within 60 minutes. This is a hard ceiling, not a rough target: the program must not run meaningfully shorter or longer than 60 minutes. Budget your exercise count, sets, and rest periods with that full 60-minute total in mind. That's typically 5-8 exercises: 1-2 primary compound lifts matching the day's focus, 2-3 secondary/accessory movements for supporting muscle groups, and 1-2 isolation, core, or conditioning exercises to finish. A single-exercise 'day' is never acceptable. " +
          "If a day's focus or the client's goals call for cardio machine work (catalog exercises with primaryMuscle 'cardio': Treadmill Run, Stair Climber, Elliptical, Rowing Machine, Ski Erg, Assault Bike, and similar), it counts toward the same 60-minute total like everything else — it is never extra time on top of the budget. Including cardio means trimming the strength portion (fewer exercises and/or sets) so the whole session, cardio included, still fits in 60 minutes. Cardio pieces should almost always use 'm' (minutes) for their time value, not 's'. " +
          "Every exercise within a single day MUST be a DIFFERENT exercise — never repeat the same exerciseId twice in one day (or across the week unless it's a deliberate, clearly-different rep scheme on a different day, e.g. a heavy day and a light day for the same lift is fine, but never two identical entries back to back in one day). " +
          "NEVER suggest a weight/load for any exercise, under any circumstances — there is no 'weight' field in your output at all. Every client starts at 0 lbs; loading and progression are decided live by the coach during the session, not by you. " +
          "REST IS CAPPED AT 2 MINUTES, ALWAYS — no rest or break interval anywhere in the program (between sets, between exercises, or between circuit rounds) may ever exceed 2 minutes ('2m'), no matter how heavy or compound the lift is. Use shorter rests (e.g. '45s'-'90s') for accessory/isolation work and reserve the full '2m' for the heaviest compound sets — never go above it. " +
          "CRITICAL formatting rule for sets/reps/distance: every one of these must be a SINGLE PLAIN NUMBER as a string — e.g. '3', '10'. NEVER a range like '8-10' or '3-4', and NEVER include units or words like 'reps', 'to failure', or 'AMRAP'. Pick ONE specific number that fits the client's level, not a range. 'time' and 'rest' are the two exceptions — see their schema descriptions for the required 's'/'m' suffix (e.g. rest '60s' for accessory work, up to '2m' for heavy compounds, never more; time '30s' for a hold, '5m' for cardio). Leave a field as an empty string only when it's genuinely not applicable (e.g. distance for a non-cardio exercise). Fill in every field that's relevant to that exercise's type — a barbell lift needs sets/reps/rest; a timed core hold or cardio interval needs time and/or distance instead — never leave a relevant field blank. " +
          "Set laterality correctly per exercise, not just the default: 'unilateral' for single-arm/single-leg movements (e.g. Bulgarian Split Squat, Single-Arm Row), 'alternating' for exercises performed alternating sides within a set (e.g. Walking Lunge, Alternating Dumbbell Curl), and 'bilateral' for standard two-sided movements. " +
          "Write a short, genuinely useful coaching cue in 'notes' for at least the primary compound lifts each day (e.g. a form cue, tempo note, or why this exercise fits the client's stated goal/limitation) — don't leave every notes field blank. " +
          "Pick exercises ONLY by id from the supplied catalog — never invent an exerciseId. " +
          "Base the split and each day's focus/title on the client's stated goals, experience level, equipment access, and any injuries/limitations noted in the physical assessment. " +
          (hasTraining && !hasPhysical ? "No Physical Assessment has been conducted yet for this client — design a safe, general-population-appropriate program from the intake answers alone, and default to moderate intensity and common, low-risk exercises rather than anything aggressive. " : "") +
          (hasPhysical && !hasTraining ? "No Personal Training Intake has been completed yet for this client — only the coach-conducted Physical Assessment is available. Infer reasonable general-fitness goals from the assessment's own notes/summary, default to a balanced full-body split, and favor exercises the assessment suggests they move well in. " : "") +
          "Prefer safer regressions (easier variations of the same movement pattern, e.g. an incline or knee push-up instead of a standard one) when an injury or limitation is mentioned near that movement pattern, and progress exercise difficulty across days as appropriate for the client's stated experience level. " +
          "Pair 2-3 complementary exercises into supersets where it fits the program style (e.g. antagonist pairs, or a client whose intake mentions limited time) using supersetGroup — otherwise leave exercises standalone. " +
          // ── Suggested days ──────────────────────────────────────────────
          "SUGGESTED DAYS follow DIFFERENT rules from everything above, and the 60-minute rule does NOT apply to them. A suggested day is 30-45 minutes of movement and conditioning: walking, running, rowing, ski erg, bike, stair climber, battle ropes, sled work, carries, walking lunges, squat to press, wall balls, or a circuit of those. It is 1-4 exercises, and ONE is completely acceptable — 'Walk, 40 minutes' is a finished suggested day and often the best one. Never pad a suggested day out to look like a gym session. " +
          "A suggested day must serve the SAME goal as the committed program, specifically. A client prepping for HYROX gets running and HYROX-style circuits (ski erg, sled push, farmer carry, wall balls, rowing, burpees). An endurance client gets steady runs. A fat-loss client gets steady-state work and brisk walking. A general-health client gets walking. Never a second strength session in disguise: no barbell or machine strength lifts on a suggested day. " +
          "MATCH THE INTENSITY TO WHAT IS LEFT OVER. These days exist to add useful work without eating the recovery that makes the committed sessions productive. Default to the easier option — a walk, an easy jog, a steady row — and only reach for hard conditioning (sprints, intervals, tempo runs, heavy sled work) when the client is experienced AND the goal genuinely demands that intensity. If the committed block is already heavy, the right suggested day is an easy one. Never place a hard conditioning day immediately after a heavy lower-body committed day. " +
          "Give every suggested day a 'rationale': one sentence on why THIS day earns its place for THIS client's goal. Give every suggested day a title that reads as what it is (e.g. 'Easy aerobic run', 'Recovery walk', 'HYROX circuit'). " +
          "Cardio and conditioning exercises take 'time' (and 'distance' where it fits) rather than sets and reps — a walk is time, not 3 sets of 10. Leave sets/reps empty on those.",
        messages: [{
          role: "user",
          // Documents and images lead the message and the framing text comes
          // last, which is the order the API docs call for.
          content: [
            ...attachments.blocks,
            { type: "text", text:
            (attachments.included.length
              ? `The client attached these files to their intake: ${attachments.included.join(", ")}. They are included above — read them and let them shape the program. Where a document contradicts a questionnaire answer, trust the document and note why in the relevant day's notes.\n\n`
              : "") +
            `DAY COUNTS FOR THIS CLIENT (already decided — produce exactly these):\n` +
            `  Committed days: ${committedDays}\n` +
            `  Suggested days: ${suggestedCount}\n` +
            (suggestedCount === 0
              ? "  Produce NO suggested days at all for this client. Return only the committed days.\n"
              : `  Produce exactly ${suggestedCount}, listed after the committed days, each with kind:"suggested" and a rationale.\n`) +
            (suggestedReasons.length
              ? `  Why that suggested count (for your context — do not restate it back):\n${suggestedReasons.map((r) => `    - ${r}`).join("\n")}\n`
              : "") +
            "\n" +
            (hasTraining
              ? `Personal Training Intake answers:\n${JSON.stringify(intake.personalTraining.answers || {}, null, 2)}\n\n`
              : "Personal Training Intake: not completed yet — not available.\n\n") +
            (hasPhysical
              ? `Physical Assessment (coach-conducted):\n${JSON.stringify({
                  scores: intake.physical.scores, observations: intake.physical.observations, notes: intake.physical.notes,
                  painScreen: intake.physical.painScreen, overall: intake.physical.overall,
                  programmingFlags: intake.physical.programmingFlags, coachSummary: intake.physical.coachSummary,
                }, null, 2)}\n\n`
              : "Physical Assessment: not completed yet — not available.\n\n") +
            `Exercise catalog (only use these ids):\n${JSON.stringify(catalog)}` },
          ],
        }],
        output_config: { format: { type: "json_schema", schema: PROGRAM_SCHEMA } },
      }),
    });
    if (!anthropicRes.ok) {
      const errBody = await anthropicRes.text();
      // Same reasoning as generate-ai-nutrition-program: a raw JSON error
      // object in a dialog tells a coach nothing they can act on.
      console.error(`anthropic ${anthropicRes.status}: ${errBody}`);
      if (anthropicRes.status === 401 || anthropicRes.status === 403) {
        throw new Error(
          "AI drafting isn't set up right now — the Anthropic API key is missing or no longer valid. " +
          "Ask your administrator to update ANTHROPIC_API_KEY.",
        );
      }
      if (anthropicRes.status === 429) {
        throw new Error("The AI service is busy right now. Wait a minute and try again.");
      }
      if (errBody.includes("credit_balance_too_low")) {
        throw new Error("The Anthropic account is out of credit. Ask your administrator to top it up.");
      }
      throw new Error(`Couldn't draft this program (${anthropicRes.status}). Please try again.`);
    }
    const message = await anthropicRes.json();
    if (message.stop_reason === "refusal") throw new Error("Claude declined to draft this program.");
    const textBlock = (message.content || []).find((b: any) => b.type === "text");
    if (!textBlock) throw new Error("Claude returned no draft content.");
    const parsed = JSON.parse(textBlock.text);

    // Only CONSECUTIVE exercises sharing the same non-empty supersetGroup label
    // become a real superset — mirrors ProgramBuilder.jsx's own coupleWithNext,
    // which only ever pairs an exercise with the next one in the list. A run of
    // 3+ matching labels in a row correctly becomes one shared supersetId
    // (a triset), same as chaining "Couple with next" twice by hand would.
    function assignSupersets(exercises: any[]) {
      return exercises.map((ex, i) => {
        const group = ex._supersetGroup;
        if (!group) return ex;
        const prevMatches = i > 0 && exercises[i - 1]._supersetGroup === group;
        const nextMatches = i < exercises.length - 1 && exercises[i + 1]._supersetGroup === group;
        if (!prevMatches && !nextMatches) return ex; // a lone exercise claiming a group of one isn't a real superset
        const supersetId = prevMatches ? exercises[i - 1]._supersetId : uid();
        exercises[i]._supersetId = supersetId; // so the NEXT iteration's prevMatches check can inherit it too (3+ in a row)
        return { ...ex, supersetId };
      }).map(({ _supersetGroup, _supersetId, ...rest }: any) => rest);
    }

    // Belt-and-suspenders for the "single plain number, no ranges/units"
    // rule — the prompt asks for this, but output_config.format can't
    // structurally enforce a string pattern here any more than it could
    // enforce array length (see the minItems failure above), so guarantee
    // it in code: keep only the first run of digits found ("8-10" -> "8",
    // "60s" -> "60", "to failure" -> ""), never a range or trailing units.
    function sanitizeNumericField(value: any): string {
      if (value == null) return "";
      const match = String(value).match(/\d+/);
      return match ? match[0] : "";
    }
    // 'time' and 'rest' keep their unit letter (unlike every other numeric
    // field) so '30s' and '5m' stay distinguishable — grabs the digits plus
    // whatever s/m letter immediately follows them ("45 sec" -> "45s",
    // "5min" -> "5m"); defaults to seconds if Claude left the letter off
    // entirely.
    function sanitizeDurationField(value: any): string {
      if (value == null) return "";
      const match = String(value).match(/(\d+)\s*([smSM])/);
      if (match) return `${match[1]}${match[2].toLowerCase()}`;
      const numOnly = String(value).match(/\d+/);
      return numOnly ? `${numOnly[0]}s` : "";
    }
    // Belt-and-suspenders for the 2-minute rest cap (AI Workout Programming
    // spec, requirement 3) — the prompt asks for this, but nothing about
    // output_config.format can structurally enforce a numeric ceiling on a
    // string field, so clamp it here too: anything over 120s gets capped
    // down to exactly '2m' rather than trusting Claude followed the rule.
    function clampRestField(value: any): string {
      const sanitized = sanitizeDurationField(value);
      if (!sanitized) return sanitized;
      const match = sanitized.match(/^(\d+)([sm])$/);
      if (!match) return sanitized;
      const seconds = match[2] === "m" ? Number(match[1]) * 60 : Number(match[1]);
      return seconds > 120 ? "2m" : sanitized;
    }

    const programDays = (parsed.days || []).map((day: any) => {
      const seenExerciseIds = new Set<string>();
      const kind = day.kind === "suggested" ? "suggested" : "committed";
      return {
        id: uid(),
        title: day.title || "Day",
        kind,
        // Only a suggested day carries one, and only if Claude wrote it —
        // an empty string here would render as a blank line on the card.
        rationale: kind === "suggested" && typeof day.rationale === "string" && day.rationale.trim()
          ? day.rationale.trim()
          : null,
        exercises: assignSupersets(
          (day.exercises || [])
            .filter((ex: any) => {
              // Valid catalog id, and never the same exercise twice in one
              // day — drop the repeat rather than error, so a mostly-good
              // response still saves; if that leaves too few exercises,
              // the minimum-exercises check below catches it instead.
              if (!exerciseMap.has(ex.exerciseId) || seenExerciseIds.has(ex.exerciseId)) return false;
              seenExerciseIds.add(ex.exerciseId);
              return true;
            })
            .map((ex: any) => {
              const real = exerciseMap.get(ex.exerciseId);
              return {
                id: uid(), exerciseId: ex.exerciseId, name: real.name, group: real.primaryMuscle || null,
                sets: sanitizeNumericField(ex.sets), reps: sanitizeNumericField(ex.reps),
                // No weight suggestions, ever — AI Workout Programming spec,
                // requirement 2. Every client starts at 0 lbs; the coach
                // sets loading live during the session.
                weight: "", time: sanitizeDurationField(ex.time),
                distance: sanitizeNumericField(ex.distance), rest: clampRestField(ex.rest),
                notes: ex.notes || "", supersetId: null, laterality: ex.laterality || "bilateral",
                _supersetGroup: ex.supersetGroup || null,
              };
            })
        ),
      };
    });
    if (!programDays.some((d: any) => d.exercises.length)) throw new Error("Claude's draft didn't reference any valid exercises.");

    // A suggested day Claude produced beyond the allowance is dropped rather
    // than argued with: the count is the code's decision, and the whole point
    // of deciding it here was that it can't drift. Committed days are kept as
    // returned — a wrong number there is a real failure, caught just below.
    const committed = programDays.filter((d: any) => d.kind === "committed");
    const suggested = programDays.filter((d: any) => d.kind === "suggested").slice(0, suggestedCount);
    const trimmedSuggested = programDays.filter((d: any) => d.kind === "suggested").length - suggested.length;
    if (trimmedSuggested > 0) {
      console.warn(`dropped ${trimmedSuggested} suggested day(s) over the allowance of ${suggestedCount}`);
    }
    // A suggested day with nothing in it is worse than no suggested day.
    const usableSuggested = suggested.filter((d: any) => d.exercises.length > 0);
    const orderedDays = [...committed, ...usableSuggested];
    // output_config.format can only guarantee the JSON *shape*, not how
    // many items are in each array — the API rejects a numeric minItems
    // constraint on this schema (see index.ts history), so richness is
    // only prompt-enforced, not schema-enforced. Fail loudly here rather
    // than silently saving another sparse draft if the prompt still
    // wasn't followed — a coach re-hitting "Regenerate" gets a real error
    // instead of the same thin result.
    if (committed.length < 2) throw new Error(`Claude's draft only had ${committed.length} committed day(s) — expected at least 2. Try regenerating.`);
    // Deliberately committed-only. A suggested day is 30-45 minutes of
    // conditioning and is frequently ONE exercise — "Walk, 40 minutes" is a
    // complete day. Applying the full-session rule to it would reject exactly
    // the output the spec asks for.
    const thinDay = committed.find((d: any) => d.exercises.length < 3);
    if (thinDay) throw new Error(`Claude's draft had a committed day ("${thinDay.title}") with only ${thinDay.exercises.length} exercise(s) — expected a full session. Try regenerating.`);

    // Only present when Claude flagged a days/week-vs-2x-per-muscle-group
    // tradeoff (see PROGRAM_SCHEMA.programNote) — surfaced to the coach on
    // the AI Draft review card (ProgramsPanel.jsx) so they know why, e.g.,
    // the focus muscle group got priority over full 2x/week coverage.
    const programNote = typeof parsed.programNote === "string" && parsed.programNote.trim() ? parsed.programNote.trim() : null;

    const entry = {
      id: uid(),
      // Counts the committed days only. That is the commitment the client
      // made and the number they recognise; suggested days are a ceiling they
      // may never use, so folding them in would overstate the program.
      name: `${clientName} - (${committed.length}) per week`,
      type: "workout", status: "draft", source: "ai",
      createdAt: stamp(), createdBy: "AI (draft)", modifiedAt: stamp(),
      assignedClientId: clientId, assignedClientName: clientName,
      programDays: orderedDays, programNote,
      // Shown on the coach's draft card so the suggested-day count can be
      // read back rather than guessed at — including, importantly, when it
      // is zero and the coach wonders why none appeared.
      suggestedNote: [restDayNote, ...suggestedReasons].filter(Boolean).join(" ") || null,
    };

    const nextPrograms = forceRegenerate
      ? [...savedPrograms.filter((p: any) => !(p.type === "workout" && p.source === "ai" && p.status === "draft")), entry]
      : [...savedPrograms, entry];

    const { error: upsertErr } = await admin.from("client_records")
      .upsert({ profile_id: clientId, data: { ...record, savedPrograms: nextPrograms } });
    if (upsertErr) throw upsertErr;

    return new Response(JSON.stringify({ ok: true, programId: entry.id }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("generate-ai-workout-program failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
