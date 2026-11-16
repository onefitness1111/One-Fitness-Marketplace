// Ends a freeze early. Proposed replacement. Not deployed until you deploy
// this function. Only the owner can resume a membership immediately. A coach
// sends an unfreeze request, and this runs after the owner approves it.
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
    const { clientId } = await req.json();
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
      throw new Error("Only the owner can resume a membership. Send an unfreeze request and the owner will decide.");
    }

    const { data: clientRow, error: clientErr } = await admin.from("clients")
      .select("stripe_subscription_id, membership_paused_at, membership_paused_days")
      .eq("profile_id", clientId).maybeSingle();
    if (clientErr) throw clientErr;

    if (clientRow?.stripe_subscription_id) {
      try {
        await stripe.subscriptions.update(clientRow.stripe_subscription_id, { pause_collection: null as unknown as string });
      } catch (e) {
        console.warn("unfreeze-membership: Stripe resume failed, continuing:", e instanceof Error ? e.message : String(e));
      }
    }

    const bankedSoFar = clientRow?.membership_paused_days || 0;
    const elapsedDays = clientRow?.membership_paused_at
      ? Math.max(0, Math.round((Date.now() - new Date(clientRow.membership_paused_at + "T00:00:00Z").getTime()) / 86400000))
      : 0;

    const { error: updateErr } = await admin.from("clients").update({
      membership_paused: false,
      membership_paused_at: null,
      membership_freeze_ends_at: null,
      membership_paused_days: bankedSoFar + elapsedDays,
    }).eq("profile_id", clientId);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("unfreeze-membership failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
