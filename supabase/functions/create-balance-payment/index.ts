// A client paying off a negative balance from the Payment Sheet. The amount is
// the balance on file right now (never taken from the app). stripe-webhook
// credits the balance when the payment succeeds (metadata.kind =
// "balance_payment"), which lifts the booking block.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const STRIPE_API_VERSION = "2024-06-20";
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: STRIPE_API_VERSION,
  httpClient: Stripe.createFetchHttpClient(),
});
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: clientRow } = await admin.from("clients")
      .select("stripe_customer_id, balance_cents").eq("profile_id", user.id).maybeSingle();
    const owed = -Number(clientRow?.balance_cents ?? 0);
    if (owed <= 0) throw new Error("You don't have a balance to pay.");

    const { data: profile } = await admin.from("profiles").select("email, name").eq("id", user.id).maybeSingle();
    let customerId = clientRow?.stripe_customer_id || null;
    if (!customerId || !(await customerIsUsable(stripe, customerId))) {
      const customer = await stripe.customers.create({
        email: profile?.email ?? undefined,
        name: profile?.name ?? undefined,
        metadata: { profile_id: user.id },
      });
      customerId = customer.id;
      await admin.from("clients").update({ stripe_customer_id: customerId }).eq("profile_id", user.id);
    }

    const ephemeralKey = await stripe.ephemeralKeys.create({ customer: customerId }, { apiVersion: STRIPE_API_VERSION });
    const intent = await stripe.paymentIntents.create({
      amount: owed,
      currency: "usd",
      customer: customerId,
      payment_method_types: ["card", "us_bank_account"],
      setup_future_usage: "off_session",
      description: "Outstanding balance",
      metadata: { profile_id: user.id, kind: "balance_payment" },
    });

    return json({
      clientSecret: intent.client_secret,
      ephemeralKey: ephemeralKey.secret,
      customerId,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      amountCents: owed,
      allowedMethods: { card: true, ach: true, applePay: true },
      requiresPayment: true,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("create-balance-payment failed:", message);
    return json({ error: message }, 400);
  }
});
