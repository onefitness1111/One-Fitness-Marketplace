// Freezes a client's membership for a bounded window.
//
// Proposed replacement. Not deployed until you deploy this function.
// The owner can still freeze immediately. A coach cannot: they send a
// request, the owner approves it, and it starts after 48 hours
// (see apply-due-requests).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

    const { data: clientRow, error: clientErr } = await admin.from("clients").select("stripe_subscription_id").eq("profile_id", clientId).maybeSingle();
    if (clientErr) throw clientErr;

    if (clientRow?.stripe_subscription_id) {
      const resumesAt = Math.floor(new Date(endDate + "T12:00:00Z").getTime() / 1000);
      await stripe.subscriptions.update(clientRow.stripe_subscription_id, {
        pause_collection: { behavior: "void", resumes_at: resumesAt },
      });
    }

    const { error: updateErr } = await admin.from("clients").update({
      membership_paused: true,
      membership_paused_at: startDate,
      membership_freeze_ends_at: endDate,
    }).eq("profile_id", clientId);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("freeze-membership failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
