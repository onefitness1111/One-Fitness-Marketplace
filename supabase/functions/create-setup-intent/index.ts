// Add a card without buying anything.
//
// Proposed replacement. Not deployed until you deploy this function.
// A client can add a card to their own account. The owner can add one to
// any client's account, and so can any coach. Clients are not assigned to
// a coach. The billing address
// is collected in the app before this runs, and a coach is not given the
// street once an address is already on file.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCoachPermission } from "../_shared/coachPermissions.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const STRIPE_API_VERSION = "2024-06-20";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const secret = Deno.env.get("STRIPE_SECRET_KEY");
    if (!secret) throw new Error("Card payments aren't set up yet — ask ONE Fitness to finish Stripe setup.");
    const stripe = new Stripe(secret, { apiVersion: STRIPE_API_VERSION, httpClient: Stripe.createFetchHttpClient() });

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

    const { clientId } = await req.json().catch(() => ({}));
    let targetId = user.id;
    if (clientId && clientId !== user.id) targetId = clientId;
    const { data: clientRow } = await admin
      .from("clients")
      .select("stripe_customer_id")
      .eq("profile_id", targetId)
      .maybeSingle();
    if (targetId !== user.id) {
      const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      const role = me?.role ?? "";
      const allowed = role === "owner" || role === "coach";
      if (!allowed) throw new Error("Not allowed to add a payment method for that client.");
      await requireCoachPermission(admin, user.id, role, "billing_access");
    }

    let customerId = clientRow?.stripe_customer_id as string | null;
    if (!customerId || !(await customerIsUsable(stripe, customerId))) {
      const { data: profile } = await admin.from("profiles").select("email, name").eq("id", targetId).maybeSingle();
      const customer = await stripe.customers.create({
        email: profile?.email ?? undefined,
        name: profile?.name ?? undefined,
        metadata: { profile_id: targetId },
      });
      customerId = customer.id;
      await admin.from("clients").update({ stripe_customer_id: customerId }).eq("profile_id", targetId);
    }

    const ephemeralKey = await stripe.ephemeralKeys.create({ customer: customerId }, { apiVersion: STRIPE_API_VERSION });
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ["card", "us_bank_account"],
      usage: "off_session",
      metadata: { profile_id: targetId },
    });

    return new Response(JSON.stringify({
      setupIntentClientSecret: setupIntent.client_secret,
      ephemeralKey: ephemeralKey.secret,
      customerId,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
    }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("create-setup-intent failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
