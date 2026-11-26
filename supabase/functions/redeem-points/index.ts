// Redeems points against an ALREADY-ACTIVE subscription — {clientId}
// (defaults to the caller). There's no invoice entity and no app-side hook
// into Stripe's own automatic renewal billing clock in this codebase, so
// this can't "schedule a discount for next month" the way a brand-new
// checkout can (see create-checkout-session, which discounts unit_amount
// directly). Instead it credits Stripe Customer Balance right now —
// Stripe automatically applies that credit to whatever the subscription's
// next invoice turns out to be, with zero scheduling needed on our side.
// First use of this Stripe primitive in this codebase.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger, planRedemption, pointsToDiscountCents } from "../_shared/pointsLedger.ts";

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
    const body = await req.json().catch(() => ({}));

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const clientId = body.clientId || user.id;
    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const isSelf = user.id === clientId;
    const isStaff = callerProfile && ["owner", "coach"].includes(callerProfile.role);
    if (!isSelf && !isStaff) throw new Error("Not authorized for this client.");

    const { data: clientRow, error: clientErr } = await admin.from("clients")
      .select("stripe_customer_id, stripe_subscription_id, membership_plan_id").eq("profile_id", clientId).maybeSingle();
    if (clientErr) throw clientErr;
    if (!clientRow?.stripe_customer_id || !clientRow?.stripe_subscription_id) {
      throw new Error("This client doesn't have an active subscription to redeem points against.");
    }

    const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", clientRow.membership_plan_id).maybeSingle();
    const priceCents = planRow?.data?.priceCents || 0;
    if (priceCents <= 0) throw new Error("Couldn't determine this client's plan price.");

    const { data: allRows } = await admin.from("points_ledger").select("*").eq("client_id", clientId);
    const { lots } = replayLedger(allRows || []);
    const plan = planRedemption(lots, new Date(), { capPoints: 40, minPoints: 40 });
    if (!plan) throw new Error("Not enough points to redeem — a minimum of 40 points is required.");

    const discountCents = pointsToDiscountCents(plan.points, priceCents);

    const balanceTxn = await stripe.customers.createBalanceTransaction(clientRow.stripe_customer_id, {
      amount: -discountCents,
      currency: "usd",
      description: `ONE Fitness rewards: ${plan.points} points redeemed for $${(discountCents / 100).toFixed(2)} off next invoice`,
    });

    const nowIso = new Date().toISOString();
    const { error: insertErr } = await admin.from("points_ledger").insert({
      client_id: clientId, amount: -plan.points, type: "redeem", source: "redemption_balance",
      source_ref_id: balanceTxn.id, created_at: nowIso,
    });
    if (insertErr) throw insertErr;

    await admin.from("clients").update({ redeem_points_next_renewal: false }).eq("profile_id", clientId);

    return new Response(JSON.stringify({ ok: true, pointsRedeemed: plan.points, discountCents }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("redeem-points failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
