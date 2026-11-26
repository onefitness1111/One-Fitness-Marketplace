// Ends a freeze early. Proposed replacement. Not deployed until you deploy
// this function. Only the owner can resume a membership immediately. A coach
// sends an unfreeze request, and this runs after the owner approves it.
//
// Resumes every subscription the client has. Sessions held from the
// freeze can be used from today until the next billing day. A freeze that
// was only scheduled is cancelled instead.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { endFreeze, loadFreezeClient } from "../_shared/freezeOps.ts";
import { pacificToday } from "../_shared/membershipFreeze.mjs";

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

    const clientRow = await loadFreezeClient(admin, clientId);
    if (!clientRow) throw new Error("Couldn't find this client.");
    if (!clientRow.membership_paused && !clientRow.membership_paused_at) {
      throw new Error("This membership isn't frozen.");
    }

    const result = await endFreeze(admin, stripe, clientRow, pacificToday(), { resumeStripe: true });
    if (result.resumeFailures > 0) {
      console.warn("unfreeze-membership: some subscriptions did not resume");
    }
    const { data: after } = await admin.from("clients").select("plans").eq("profile_id", clientId).maybeSingle();

    return new Response(JSON.stringify({
      ok: true,
      cancelledScheduled: result.cancelledScheduled,
      resumeFailures: result.resumeFailures,
      plans: after?.plans ?? null,
    }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("unfreeze-membership failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
