// Freezes a client's membership for a bounded window.
//
// Proposed replacement. Not deployed until you deploy this function.
// The owner can still freeze immediately. A coach cannot: they send a
// request, the owner approves it, and it starts after 48 hours
// (see apply-due-requests).
//
// A start day after today is scheduled, not applied now: booking stays
// open and nothing is paused until that day (apply-due-requests starts it).
// Starting pauses every subscription the client has, resumes billing one
// hour before midnight Pacific on the end day, and holds this month's
// unused sessions for after the freeze (see _shared/membershipFreeze.mjs).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { loadFreezeClient, scheduleFreeze, startFreeze } from "../_shared/freezeOps.ts";
import { freezeStartsLater, pacificToday } from "../_shared/membershipFreeze.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId, startDate, endDate } = await req.json();
    if (!clientId) throw new Error("clientId is required");
    if (!startDate || !endDate) throw new Error("A start date and an end date are both required to freeze a membership.");
    if (endDate <= startDate) throw new Error("The end date must be after the start date.");

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
      throw new Error("A freeze has to be approved by the owner. Send it from Requests, with the from date, to date, and a reason.");
    }

    const isoDay = /^\d{4}-\d{2}-\d{2}$/;
    if (!isoDay.test(String(startDate)) || !isoDay.test(String(endDate))) {
      throw new Error("Dates must be YYYY-MM-DD.");
    }

    const clientRow = await loadFreezeClient(admin, clientId);
    if (!clientRow) throw new Error("Couldn't find this client.");
    if (clientRow.membership_paused) throw new Error("This membership is already frozen. Unfreeze it first to change the dates.");

    const today = pacificToday();
    if (endDate <= today) throw new Error("The end date has to be after today.");

    if (freezeStartsLater(startDate, today)) {
      await scheduleFreeze(admin, clientRow, startDate, endDate);
      return new Response(JSON.stringify({ ok: true, scheduled: true, startDate, endDate }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    await startFreeze(admin, stripe, clientRow, startDate, endDate);
    const { data: after } = await admin.from("clients").select("plans").eq("profile_id", clientId).maybeSingle();

    return new Response(JSON.stringify({ ok: true, scheduled: false, startDate, endDate, plans: after?.plans ?? null }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("freeze-membership failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
