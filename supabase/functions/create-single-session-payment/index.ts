// Starts a single-session purchase for the signed-in client. The price and the
// "single sessions allowed" flag come from platform settings here, never from
// the app. Nothing is reserved yet: the seat is only taken after Stripe says the
// payment succeeded (see confirm-single-session / stripe-webhook).
//
// Deploy with the login check left on:
//   supabase functions deploy create-single-session-payment
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";
import { sessionTypeLabel, singleSessionConfig } from "../_shared/singleSession.ts";
import { singleSessionTotal } from "../_shared/singleSessionRules.mjs";

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
    const body = await req.json().catch(() => ({}));
    const { sessionType, trainerId, date, slot, discipline, locationName } = body as Record<string, string | number>;
    if (!sessionType || !trainerId || !date || slot === undefined) throw new Error("Missing session details.");

    const authed = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: owing } = await admin.from("clients").select("balance_cents").eq("profile_id", user.id).maybeSingle();

    const cfg = await singleSessionConfig(admin, String(sessionType));
    if (!cfg.offered) throw new Error("That session type isn't offered.");
    if (!cfg.allowed) throw new Error("Single sessions aren't available for this session type — please choose a membership or package.");

    // Not in the past, and the session has to exist for this coach.
    const startMs = new Date(`${date}T00:00:00Z`).getTime() + Number(slot) * 60000;
    if (startMs < Date.now()) throw new Error("That session has already started.");

    const { data: clientRow } = await admin.from("clients").select("stripe_customer_id").eq("profile_id", user.id).maybeSingle();
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

    const bill = singleSessionTotal(cfg.priceCents, owing?.balance_cents ?? 0);
    const ephemeralKey = await stripe.ephemeralKeys.create({ customer: customerId }, { apiVersion: STRIPE_API_VERSION });
    const intent = await stripe.paymentIntents.create({
      amount: bill.totalCents,
      currency: "usd",
      customer: customerId,
      // Card covers Apple Pay and Google Pay too. No bank transfer: a seat can't
      // wait days for a transfer to clear.
      payment_method_types: ["card"],
      setup_future_usage: "off_session", // keeps the card for late-cancel / no-show fees
      description: `Single Session — ${sessionTypeLabel(String(sessionType))}`,
      metadata: {
        kind: "single_session",
        profile_id: user.id,
        session_type: String(sessionType),
        trainer_id: String(trainerId),
        date: String(date),
        slot: String(slot),
        discipline: String(discipline ?? ""),
        location_name: String(locationName ?? ""),
        unit_price_cents: String(bill.sessionCents),
        balance_cents: String(bill.balanceCents),
      },
    });

    return json({
      clientSecret: intent.client_secret,
      paymentIntentId: intent.id,
      ephemeralKey: ephemeralKey.secret,
      customerId,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      amountCents: bill.totalCents,
      sessionCents: bill.sessionCents,
      balanceCents: bill.balanceCents,
      allowedMethods: { card: true, ach: false, applePay: true },
      requiresPayment: true,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("create-single-session-payment failed:", message);
    return json({ error: message }, 400);
  }
});
