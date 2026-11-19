// The signed-in client pays the full negative balance.
// A saved card or a new card (with billing address, collected by the sheet)
// is charged. Unpaid ledger rows are marked paid and booking is unblocked.
//
// Deploy with the login check left on:
//   supabase functions deploy pay-balance
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action ?? "create");
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (me?.role !== "client") throw new Error("The client pays their own balance.");

    const { data: clientRow } = await admin
      .from("clients")
      .select("stripe_customer_id, balance_cents")
      .eq("profile_id", user.id)
      .maybeSingle();
    const owed = -Math.min(Number(clientRow?.balance_cents ?? 0), 0);
    if (action === "create" && owed <= 0) {
      return json({ ok: true, requiresPayment: false, amountCents: 0 });
    }

    const secret = Deno.env.get("STRIPE_SECRET_KEY");
    if (!secret) throw new Error("Card payments aren't set up yet.");
    const stripe = new Stripe(secret, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });

    if (action === "confirm") {
      const paymentIntentId = String(body.paymentIntentId ?? "");
      if (!paymentIntentId) throw new Error("The payment was not found.");
      const intent = await stripe.paymentIntents.retrieve(paymentIntentId);
      if (intent.metadata?.client_id !== user.id || intent.metadata?.purpose !== "balance") {
        throw new Error("That payment is not for this balance.");
      }
      if (intent.status !== "succeeded") throw new Error("The payment did not go through.");
      const pm = typeof intent.payment_method === "string" ? intent.payment_method : intent.payment_method?.id ?? null;
      if (pm && intent.customer) {
        const method = await stripe.paymentMethods.retrieve(pm);
        const address = method.billing_details?.address;
        if (address?.line1) {
          const customer = typeof intent.customer === "string" ? intent.customer : intent.customer.id;
          await stripe.customers.update(customer, {
            name: method.billing_details?.name ?? undefined,
            address: {
              line1: address.line1,
              line2: address.line2 ?? undefined,
              city: address.city ?? undefined,
              state: address.state ?? undefined,
              postal_code: address.postal_code ?? undefined,
              country: address.country ?? "US",
            },
          });
        }
      }
      const { error } = await admin.rpc("apply_balance_payment", {
        p_client: user.id,
        p_amount_cents: intent.amount,
        p_payment_intent: intent.id,
        p_payment_method: pm,
      });
      if (error) throw new Error(error.message);
      return json({ ok: true, paid: true, amountCents: intent.amount });
    }

    const customerId = await ensureCustomer(stripe, admin, user.id, clientRow?.stripe_customer_id ?? null);
    const ephemeralKey = await stripe.ephemeralKeys.create({ customer: customerId }, { apiVersion: "2024-06-20" });
    const intent = await stripe.paymentIntents.create({
      amount: owed,
      currency: "usd",
      customer: customerId,
      description: "Outstanding balance",
      metadata: { purpose: "balance", client_id: user.id },
      automatic_payment_methods: { enabled: true },
    });
    return json({
      ok: true,
      requiresPayment: true,
      amountCents: owed,
      clientSecret: intent.client_secret,
      paymentIntentId: intent.id,
      customerId,
      ephemeralKey: ephemeralKey.secret,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return json({ error: message }, 400);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

// deno-lint-ignore no-explicit-any
async function ensureCustomer(stripe: Stripe, admin: any, clientId: string, existing: string | null) {
  if (existing) return existing;
  const { data: profile } = await admin.from("profiles").select("email, name").eq("id", clientId).maybeSingle();
  const customer = await stripe.customers.create({
    email: profile?.email ?? undefined,
    name: profile?.name ?? undefined,
    metadata: { profile_id: clientId },
  });
  await admin.from("clients").update({ stripe_customer_id: customer.id }).eq("profile_id", clientId);
  return customer.id;
}
