// Client's own upgrade/downgrade of an existing paid subscription.
//
// Live function, plus the ghost-plan check: a client cannot switch onto a
// ghost or archived plan. Not deployed by this change.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { swapMembershipEnrollment } from "../_shared/planEnrollments.ts";
import { ensureProduct } from "../_shared/stripeProduct.ts";
import { assertPlanPurchasable } from "../_shared/planVisibility.mjs";

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
    const { newPlanId, timing } = await req.json();
    if (!newPlanId) throw new Error("newPlanId is required");
    if (timing !== "immediate" && timing !== "end_of_cycle") throw new Error("timing must be 'immediate' or 'end_of_cycle'");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

    const { data: newPlanRow, error: planErr } = await admin.from("membership_plans").select("data").eq("id", newPlanId).maybeSingle();
    if (planErr) throw planErr;
    const newPlan = newPlanRow?.data;
    if (!newPlan) throw new Error("Plan not found.");
    assertPlanPurchasable(newPlan);
    const newPriceCents = newPlan.priceCents || 0;
    if (newPriceCents <= 0) throw new Error("Switching to a free plan isn't a plan change — cancel your current plan from Membership Hub instead, then select the free plan.");
    const isNewSub = (newPlan.paymentType || (newPlan.kind === "package" ? "one-time" : "subscription")) === "subscription";
    if (!isNewSub) throw new Error("Switching to a one-time package isn't a plan change — cancel your current plan first, then purchase the package separately.");

    const { data: clientRow, error: clientErr } = await admin.from("clients")
      .select("stripe_subscription_id, membership_plan_id, plans").eq("profile_id", user.id).maybeSingle();
    if (clientErr) throw clientErr;
    if (!clientRow?.stripe_subscription_id) throw new Error("You don't have an active subscription to change — pick a plan from Membership Hub instead.");

    const recurring = { interval: "month" as const, interval_count: newPlan.billingIntervalMonths || 1 };

    if (timing === "immediate") {
      const sub = await stripe.subscriptions.retrieve(clientRow.stripe_subscription_id);
      const itemId = sub.items.data[0]?.id;
      if (!itemId) throw new Error("Couldn't find your current subscription's billing item.");

      await stripe.subscriptions.update(clientRow.stripe_subscription_id, {
        items: [{
          id: itemId,
          price_data: {
            currency: "usd",
            unit_amount: newPriceCents,
            product: await ensureProduct(stripe, `plan_${newPlanId}`, newPlan.name || "Membership Plan"),
            recurring,
          },
        }],
        proration_behavior: "create_prorations",
        metadata: { ...sub.metadata, plan_id: newPlanId },
      });

      const oldUsableUntil = new Date(sub.current_period_end * 1000).toISOString().slice(0, 10);

      const { error: updateErr } = await admin.from("clients").update({
        membership_plan_id: newPlanId,
        plans: swapMembershipEnrollment(clientRow.plans, clientRow.membership_plan_id, newPlanId, newPlan.termMonths ?? null, clientRow.stripe_subscription_id, oldUsableUntil),
        pending_plan_id: null, pending_plan_effective_at: null, pending_plan_price_id: null, stripe_schedule_id: null,
      }).eq("profile_id", user.id);
      if (updateErr) throw updateErr;

      return new Response(JSON.stringify({ ok: true, effective: "immediate" }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const { data: existingClientRow } = await admin.from("clients").select("stripe_schedule_id").eq("profile_id", user.id).maybeSingle();
    const schedule = existingClientRow?.stripe_schedule_id
      ? await stripe.subscriptionSchedules.retrieve(existingClientRow.stripe_schedule_id)
      : await stripe.subscriptionSchedules.create({ from_subscription: clientRow.stripe_subscription_id });

    const phase1 = schedule.phases[0];
    if (!phase1?.end_date) throw new Error("Couldn't determine your current renewal date — try again, or contact support.");

    const newPrice = await stripe.prices.create({
      currency: "usd",
      unit_amount: newPriceCents,
      recurring,
      product_data: { name: newPlan.name || "Membership Plan" },
    });

    await stripe.subscriptionSchedules.update(schedule.id, {
      end_behavior: "release",
      phases: [
        {
          items: phase1.items.map((it: { price: unknown; quantity?: number }) => ({ price: it.price as string, quantity: it.quantity ?? 1 })),
          start_date: phase1.start_date,
          end_date: phase1.end_date,
        },
        {
          items: [{ price: newPrice.id, quantity: 1 }],
        },
      ],
    });

    const effectiveAt = new Date(phase1.end_date * 1000).toISOString().slice(0, 10);
    const { error: updateErr } = await admin.from("clients").update({
      pending_plan_id: newPlanId,
      pending_plan_effective_at: effectiveAt,
      pending_plan_price_id: newPrice.id,
      stripe_schedule_id: schedule.id,
    }).eq("profile_id", user.id);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ ok: true, effective: "end_of_cycle", effectiveAt }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("change-membership-plan failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
