// Runs every hour (pg_cron) and when the owner opens Requests.
//
// 1. Starts freezes the owner already approved, once the 48-hour wait and
//    the from-date have both passed.
// 2. Starts freezes the owner set up with a later start day (C3).
// 3. Ends every freeze whose end day has come, with or without a Stripe
//    subscription (C5). Stripe resumes billing on its own just before the
//    end day; this clears the freeze on our side for everyone else too.
//
// Starting a freeze pauses every subscription the client has and holds the
// month's unused sessions (see _shared/freezeOps.ts).
//
// Proposed. Not deployed until you deploy this function.
// A timer calls it with the header x-cron-secret set to the Vault secret
// apply_requests_cron. The password is not stored in this file or in an
// edge-function env var.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";
import { endFreeze, FREEZE_CLIENT_COLUMNS, loadFreezeClient, startFreeze } from "../_shared/freezeOps.ts";
import { pacificToday, shortDay } from "../_shared/membershipFreeze.mjs";

// deno-lint-ignore no-explicit-any
type FreezeRow = Record<string, any>;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

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
      if (profile?.role !== "owner") throw new Error("Only the owner can apply freezes.");
    }

    const today = pacificToday();
    const failures: string[] = [];

    // 1. Approved coach requests that are due.
    const { data: due, error } = await admin.rpc("due_freeze_requests");
    if (error) throw error;
    const rows = Array.isArray(due) ? due : [];
    let applied = 0;

    for (const row of rows) {
      const clientId = String(row.clientId ?? "");
      const from = String(row.from ?? "");
      const to = String(row.to ?? "");
      if (!clientId || !to) continue;
      try {
        const clientRow = await loadFreezeClient(admin, clientId);
        if (!clientRow) continue;
        if (to <= today) {
          // The whole window already passed before it could start.
          await admin.rpc("mark_request_applied", { p_id: row.id, p_booking: null });
          continue;
        }
        if (!clientRow.membership_paused) {
          await startFreeze(admin, stripe, clientRow, from || today, to);
        }
        await admin.rpc("mark_request_applied", { p_id: row.id, p_booking: null });
        await notifyProfile(
          admin,
          clientId,
          "Your membership freeze has started",
          `Your freeze is now in effect until ${shortDay(to)}. You can book sessions starting that day.`,
          true,
        );
        if (row.coachId) {
          await notifyProfile(
            admin,
            String(row.coachId),
            "A freeze you requested has started",
            `The freeze is now in effect until ${shortDay(to)}.`,
            false,
          );
        }
        applied += 1;
      } catch (_e) {
        failures.push("request");
        console.error("apply-due-requests: a freeze request could not be started");
      }
    }

    // 2. Owner freezes scheduled for a later start day.
    const { data: scheduled, error: schedErr } = await admin.from("clients")
      .select(FREEZE_CLIENT_COLUMNS)
      .eq("membership_paused", false)
      .not("membership_paused_at", "is", null)
      .lte("membership_paused_at", today);
    if (schedErr) throw new Error("Couldn't read scheduled freezes.");
    let started = 0;
    for (const clientRow of (scheduled ?? []) as FreezeRow[]) {
      try {
        const to = clientRow.membership_freeze_ends_at ? String(clientRow.membership_freeze_ends_at) : "";
        if (!to || to <= today) {
          // The window passed before it started. Drop it.
          await endFreeze(admin, null, clientRow, today, { resumeStripe: false });
          continue;
        }
        await startFreeze(admin, stripe, clientRow, String(clientRow.membership_paused_at), to);
        started += 1;
      } catch (_e) {
        failures.push("scheduled");
        console.error("apply-due-requests: a scheduled freeze could not be started");
      }
    }

    // 3. Freezes whose end day has come, Stripe or not.
    const { data: ending, error: endErr } = await admin.from("clients")
      .select(FREEZE_CLIENT_COLUMNS)
      .eq("membership_paused", true)
      .not("membership_freeze_ends_at", "is", null)
      .lte("membership_freeze_ends_at", today);
    if (endErr) throw new Error("Couldn't read freezes that have ended.");
    let ended = 0;
    for (const clientRow of (ending ?? []) as FreezeRow[]) {
      try {
        const endDay = String(clientRow.membership_freeze_ends_at);
        await endFreeze(admin, stripe, clientRow, endDay, { resumeStripe: true });
        ended += 1;
      } catch (_e) {
        failures.push("end");
        console.error("apply-due-requests: a freeze could not be ended");
      }
    }

    return new Response(JSON.stringify({ ok: true, applied, started, ended, failed: failures.length }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("apply-due-requests failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
