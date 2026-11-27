// Morning check for clients who have gone quiet.
//
// Proposed. Not deployed until you deploy this function.
// A timer calls it at 8:10am Pacific with the header x-cron-secret set to
// the Vault secret apply_requests_cron (the same secret the freeze job uses).
// The password is not stored in this file.
//
// Day 2: one phone notification. Day 3: one text from the business number,
// and an in-app plus phone alert for their coach and the owner.
// The timing matches lib/core/utils/quiet_nudge.dart.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";
import { sendAutoSms } from "../_shared/autoSms.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

type Step = "rest" | "push" | "text" | "none";

function nudgeStep(quietDays: number, pushSent: boolean, textSent: boolean): Step {
  if (quietDays < 2) return "rest";
  if (!pushSent) return "push";
  if (quietDays >= 3 && !textSent) return "text";
  return "none";
}

function pacificToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(new Date());
}

function firstName(value: unknown): string {
  const name = String(value ?? "").trim();
  return name;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const admin = createClient(url, serviceKey);

    const cron = req.headers.get("x-cron-secret");
    const { data: secretRow, error: secretErr } = await admin.rpc("cron_vault_secret");
    if (secretErr) console.error("cron vault read failed");
    const expected = typeof secretRow === "string" ? secretRow : "";
    const cronOk = expected.length > 0 && cron === expected;
    if (!cronOk) {
      const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await authed.auth.getUser();
      if (!user) throw new Error("Not signed in.");
      const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (profile?.role !== "owner") throw new Error("Only the owner can run quiet nudges.");
    }

    const today = pacificToday();
    const { data: roster, error } = await admin.rpc("quiet_nudge_roster", { p_today: today });
    if (error) throw error;
    const rows = Array.isArray(roster) ? roster : [];

    const { data: owners } = await admin
      .from("profiles")
      .select("id")
      .eq("role", "owner")
      .is("deleted_at", null)
      .is("banned_at", null);
    const ownerIds = (owners || []).map((row: { id: string }) => row.id).filter(Boolean);

    let pushed = 0;
    let texted = 0;
    let alerted = 0;
    let cleared = 0;

    for (const row of rows) {
      const clientId = String(row.client_id ?? "");
      const last = String(row.last_activity_on ?? "").slice(0, 10);
      const quietDays = Number(row.quiet_days ?? 0);
      if (!clientId || !last) continue;

      const step = nudgeStep(quietDays, row.push_sent === true, row.text_sent === true);
      if (step === "none") continue;

      if (step === "rest") {
        const { error: clearErr } = await admin.rpc("clear_quiet_nudge", {
          p_client: clientId,
          p_last: last,
        });
        if (clearErr) console.error("quiet nudge clear failed");
        else cleared += 1;
        continue;
      }

      const coachId = row.coach_id ? String(row.coach_id) : null;
      const { data: claimed, error: claimErr } = await admin.rpc("claim_quiet_nudge", {
        p_client: clientId,
        p_last: last,
        p_kind: step,
        p_today: today,
        p_coach: step === "text" ? coachId : null,
      });
      if (claimErr) {
        console.error("quiet nudge claim failed");
        continue;
      }
      if (claimed !== true) continue;

      if (step === "push") {
        await notifyProfile(
          admin,
          clientId,
          "Checking in",
          "Two days with no meal or workout logged. Whenever you're ready, it only takes a minute.",
          false,
        );
        pushed += 1;
        continue;
      }

      if (row.may_text === true && row.phone) {
        const who = firstName(row.first_name);
        const line = who
          ? `Hey ${who}, it's been 3 days since your last meal or workout log. Open the app when you can.`
          : "It's been 3 days since your last meal or workout log. Open the app when you can.";
        // may_text is the stricter nudge rule (consent evidence, no marketing
        // opt-out). sendAutoSms checks STOP / opt-in again, skips made-up
        // numbers, and holds the text for 8:00am during quiet hours.
        try {
          const outcome = await sendAutoSms(admin, { profileId: clientId, text: line, kind: "quiet-nudge", ref: today });
          if (outcome === "sent" || outcome === "deferred") texted += 1;
        } catch (e) {
          console.error("quiet nudge text failed:", e instanceof Error ? e.message : String(e));
        }
      }

      const clientLabel = firstName(row.first_name) || "A client";
      const staffTitle = "A client has gone quiet";
      const staffBody = `${clientLabel} hasn't logged a meal or a workout in 3 days.`;
      const told = new Set<string>();
      if (coachId) {
        told.add(coachId);
        await notifyProfile(admin, coachId, staffTitle, staffBody, false);
      }
      for (const ownerId of ownerIds) {
        if (told.has(ownerId)) continue;
        told.add(ownerId);
        await notifyProfile(admin, ownerId, staffTitle, staffBody, false);
      }
      alerted += 1;
    }

    return new Response(JSON.stringify({ ok: true, pushed, texted, alerted, cleared }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("quiet-nudges failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
