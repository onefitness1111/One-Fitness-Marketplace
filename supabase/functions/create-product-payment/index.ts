// Buying merchandise. Separate from create-payment-intent because a product
// is not a plan: it grants no access, has no billing cycle, and its stock has
// to be checked and decremented — none of which apply to a membership.
//
// Like the plan flow it returns what Stripe's native Payment Sheet needs, so
// card entry happens in-app with no redirect and no card data reaching us.
//
// Stock is checked here and decremented by stripe-webhook on
// payment_intent.succeeded — never at request time, or an abandoned checkout
// would permanently eat inventory nobody bought.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const STRIPE_API_VERSION = "2024-06-20";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: STRIPE_API_VERSION,
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { productId, size, quantity } = await req.json();
    if (!productId) throw new Error("productId is required");
    const qty = Math.max(1, Math.min(10, Number(quantity) || 1));

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

    // Price and stock come from the catalogue, never from the request — the
    // app could otherwise name its own price.
    const { data: row } = await admin.from("products").select("data").eq("id", productId).maybeSingle();
    const product = row?.data;
    if (!product || product.archived) throw new Error("That product isn't available.");

    const priceCents = product.priceCents || 0;
    if (priceCents <= 0) throw new Error("That product has no price set — ask your coach.");

    const sizes: Array<{ label: string; inventory: number }> = Array.isArray(product.sizes) ? product.sizes : [];
    const chosen = size ? sizes.find((s) => s.label === size) : (sizes.length === 1 ? sizes[0] : null);
    if (!chosen) throw new Error("Choose a size first.");
    if ((chosen.inventory || 0) < qty) {
      throw new Error(
        chosen.inventory > 0
          ? `Only ${chosen.inventory} left in ${chosen.label}.`
          : `${chosen.label} is sold out.`,
      );
    }

    const { data: clientRow } = await admin.from("clients")
      .select("stripe_customer_id").eq("profile_id", user.id).maybeSingle();
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

    const amountCents = priceCents * qty;
    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customerId },
      { apiVersion: STRIPE_API_VERSION },
    );

    const intent = await stripe.paymentIntents.create({
      amount: amountCents,
      currency: "usd",
      customer: customerId,
      payment_method_types: ["card", "us_bank_account"],
      setup_future_usage: "off_session",
      description: `${product.name}${chosen.label ? ` (${chosen.label})` : ""} x${qty}`,
      // product_id is what tells stripe-webhook this is merchandise rather
      // than a plan, so it decrements stock instead of granting access.
      metadata: {
        profile_id: user.id,
        product_id: productId,
        product_name: product.name ?? "",
        size: chosen.label,
        quantity: String(qty),
        unit_price_cents: String(priceCents),
      },
    });

    return new Response(JSON.stringify({
      clientSecret: intent.client_secret,
      ephemeralKey: ephemeralKey.secret,
      customerId,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      amountCents,
      // Merchandise is a one-off purchase, so every tender the packages rule
      // allows applies here too.
      allowedMethods: { card: true, ach: true, applePay: true },
      requiresPayment: true,
    }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("create-product-payment failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
