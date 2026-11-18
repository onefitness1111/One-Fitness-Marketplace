// Called by the app right after the payment sheet closes. Checks with Stripe
// (never trusts the app) that the payment succeeded, then credits and books it.
// The Stripe webhook does the same thing; whichever runs first wins and the
// other is a harmless no-op.
//
// Deploy with the login check left on:
//   supabase functions deploy confirm-single-session
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { fulfillSingleSessionPayment } from "../_shared/singleSession.ts";
import { clientBalanceMessage, clientMayBuySingle } from "../_shared/singleSessionRules.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const { paymentIntentId } = await req.json().catch(() => ({}));
    if (!paymentIntentId) throw new Error("paymentIntentId is required");

    const authed = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const pi = await stripe.paymentIntents.retrieve(String(paymentIntentId));
    if (pi.metadata?.profile_id !== user.id) throw new Error("That payment isn't yours.");
    if (pi.status !== "succeeded") return json({ status: "error", message: "The payment hasn't completed." });

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: owing } = await admin.from("clients").select("balance_cents").eq("profile_id", user.id).maybeSingle();
    if (!clientMayBuySingle(owing?.balance_cents ?? 0)) {
      const { data: already } = await admin.from("single_session_credits").select("id").eq("stripe_payment_intent_id", pi.id).maybeSingle();
      if (!already) {
        try {
          await stripe.refunds.create(
            { payment_intent: pi.id, reason: "requested_by_customer" },
            { idempotencyKey: `single-balance-${pi.id}` },
          );
        } catch (refundErr) {
          console.error("single session balance refund failed:", refundErr instanceof Error ? refundErr.message : String(refundErr));
        }
      }
      return json({ status: "error", code: "BALANCE_DUE", message: clientBalanceMessage(owing?.balance_cents ?? 0) });
    }
    const res = await fulfillSingleSessionPayment({ admin, stripe, pi });
    return json(res);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("confirm-single-session failed:", message);
    return json({ status: "error", message }, 400);
  }
});
