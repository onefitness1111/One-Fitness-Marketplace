// Refunds a real Stripe payment behind a 'purchase' charge row — owner
// only. Whether the processing fee (if one was collected alongside it)
// gets refunded too is controlled by "Refund fee when refunding a
// payment" (Settings → Customize Platform → Payments): off issues a
// partial refund for just the original subtotal (the fee is kept, same as
// most real payment processors treat their own fees); on issues a full
// refund covering both. Deployed WITH jwt verification; the owner-role
// check below is the actual authorization, same pattern as
// create-checkout-session.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger } from "../_shared/pointsLedger.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

const THIRTY_DAYS_MS = 1000 * 60 * 60 * 24 * 30;

// Duplicated from stripe-webhook/index.ts rather than cross-imported —
// _shared/ is for the pure FIFO calculator six call sites genuinely need
// identically; this DB-touching clawback is small enough that keeping each
// function self-contained (this app's existing convention) wins out.
// Untyped client (no generated DB types in this repo); type-only change.
// deno-lint-ignore no-explicit-any
async function clawbackReferral(admin: any, referredClientId: string, reasonSuffix: string) {
  const { data: referralRow } = await admin.from("points_ledger")
    .select("*").eq("source", "referral").eq("source_ref_id", referredClientId).eq("type", "earn").maybeSingle();
  if (!referralRow) return;
  if (Date.now() - new Date(referralRow.created_at).getTime() > THIRTY_DAYS_MS) return;

  const { data: existingVoid } = await admin.from("points_ledger").select("id").eq("voided_by_ledger_id", referralRow.id).maybeSingle();
  if (existingVoid) return;

  const { data: allRows } = await admin.from("points_ledger").select("*").eq("client_id", referralRow.client_id);
  const { lots } = replayLedger(allRows || []);
  const lot = lots.find((l: { id: string }) => l.id === referralRow.id);
  const remaining = lot?.remaining || 0;
  if (remaining <= 0) return;

  await admin.from("points_ledger").insert({
    client_id: referralRow.client_id, amount: -remaining, type: "void", source: "referral_clawback",
    voided_by_ledger_id: referralRow.id, reason: `Referred client's purchase was ${reasonSuffix} within 30 days.`,
    created_at: new Date().toISOString(),
  });
  console.log(`refund-charge: referral clawback — voided ${remaining} pts from ${referralRow.client_id}`);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { chargeId } = await req.json();
    if (!chargeId) throw new Error("chargeId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } }
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "owner") throw new Error("Only the owner can issue refunds.");

    const { data: charge, error: chargeErr } = await admin.from("charges").select("*").eq("id", chargeId).maybeSingle();
    if (chargeErr) throw chargeErr;
    if (!charge) throw new Error("Charge not found.");
    if (charge.type !== "purchase") throw new Error("Only a purchase charge can be refunded.");
    if (!charge.stripe_payment_intent_id) throw new Error("This charge has no linked Stripe payment (likely a subscription renewal) — refund it directly in the Stripe Dashboard instead.");

    const { data: settingsRow } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
    const refundFee = !!settingsRow?.data?.payments?.refundFeeOnRefund;

    const { data: feeCharge } = await admin.from("charges")
      .select("amount")
      .eq("stripe_payment_intent_id", charge.stripe_payment_intent_id)
      .eq("type", "processing_fee")
      .maybeSingle();
    const feeCents = Math.round((feeCharge?.amount || 0) * 100);
    const subtotalCents = Math.round(charge.amount * 100);
    const refundCents = refundFee ? subtotalCents + feeCents : subtotalCents;

    const refund = await stripe.refunds.create({ payment_intent: charge.stripe_payment_intent_id, amount: refundCents });

    const { error: insertErr } = await admin.from("charges").insert({
      client_id: charge.client_id,
      client_name: charge.client_name,
      type: "refund",
      date: new Date().toISOString().slice(0, 10),
      at: new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
      amount: -(refundCents / 100),
      category: charge.category,
      plan_id: charge.plan_id,
      plan_name: charge.plan_name,
      stripe_payment_intent_id: charge.stripe_payment_intent_id,
    });
    if (insertErr) throw insertErr;

    // A single-session purchase: the refunded credit can't be used any more.
    // (A session already booked with it is left for the owner to cancel.)
    if (charge.category === "Single Session") {
      await admin.from("single_session_credits").update({ status: "refunded" })
        .eq("stripe_payment_intent_id", charge.stripe_payment_intent_id);
    }

    await clawbackReferral(admin, charge.client_id, "refunded");

    console.log(`refund-charge: owner ${user.id} refunded ${refundCents} cents for charge ${chargeId} (stripe refund ${refund.id})`);
    return new Response(JSON.stringify({ ok: true, refundedCents: refundCents }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("refund-charge failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
