// Owner-only: see and override what a client's membership renews at, when it
// renews, and when it ends.
//
//   { clientId, action: "get" }
//     -> { hasSubscription, planPriceCents, renewalPriceCents, interval,
//          nextRenewalDate, endsOn, status }
//   { clientId, action: "update", renewalPriceCents?, renewalDate?, endsOn?, clearEnd? }
//
// renewalPriceCents  a new recurring price on the live subscription. No
//                    proration and no charge now — it only changes what the
//                    NEXT renewals bill.
// renewalDate        YYYY-MM-DD, in the future. Moves the next charge to that
//                    day (Stripe trial_end, no proration).
// endsOn / clearEnd  the date the membership expires (Stripe cancel_at), or
//                    removes a scheduled end.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

const isoDay = (ts: number | null | undefined) => (ts ? new Date(ts * 1000).toISOString().slice(0, 10) : null);
function dayToTs(day: string): number {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error("Dates must look like YYYY-MM-DD.");
  return Math.floor(new Date(day + "T12:00:00Z").getTime() / 1000);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const { clientId, action, renewalPriceCents, renewalDate, endsOn, clearEnd } = await req.json();
    if (!clientId) throw new Error("clientId is required");

    const authed = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (me?.role !== "owner") throw new Error("Only the owner can change what a membership renews at.");

    const { data: row } = await admin.from("clients")
      .select("stripe_subscription_id, membership_plan_id").eq("profile_id", clientId).maybeSingle();
    if (!row) throw new Error("That client no longer exists.");

    let planPriceCents: number | null = null;
    if (row.membership_plan_id) {
      const { data: plan } = await admin.from("membership_plans").select("data").eq("id", row.membership_plan_id).maybeSingle();
      planPriceCents = plan?.data?.priceCents ?? null;
    }

    if (!row.stripe_subscription_id) {
      return json({ hasSubscription: false, planPriceCents });
    }

    let sub = await stripe.subscriptions.retrieve(row.stripe_subscription_id);
    const item = sub.items.data[0];
    if (!item) throw new Error("This subscription has no price on it.");

    if (action === "update") {
      const updates: Stripe.SubscriptionUpdateParams = { proration_behavior: "none" };

      if (renewalPriceCents != null) {
        const cents = Math.round(Number(renewalPriceCents));
        if (!Number.isFinite(cents) || cents < 0) throw new Error("Enter a valid price.");
        const price = await stripe.prices.create({
          unit_amount: cents,
          currency: item.price.currency,
          product: typeof item.price.product === "string" ? item.price.product : item.price.product.id,
          recurring: { interval: item.price.recurring?.interval ?? "month", interval_count: item.price.recurring?.interval_count ?? 1 },
          metadata: { owner_override: "true", set_by: user.id },
        });
        updates.items = [{ id: item.id, price: price.id }];
      }

      if (renewalDate) {
        const ts = dayToTs(renewalDate);
        if (ts <= Math.floor(Date.now() / 1000) + 3600) throw new Error("The renewal date must be in the future.");
        updates.trial_end = ts;
      }

      if (clearEnd) {
        updates.cancel_at = null;
        updates.cancel_at_period_end = false;
      } else if (endsOn) {
        const ts = dayToTs(endsOn);
        if (ts <= Math.floor(Date.now() / 1000)) throw new Error("The expiration date must be in the future.");
        updates.cancel_at = ts;
      }

      if (Object.keys(updates).length > 1) {
        sub = await stripe.subscriptions.update(sub.id, updates);
        console.log(`owner-subscription-terms: ${user.id} updated ${clientId}: ${JSON.stringify({ renewalPriceCents, renewalDate, endsOn, clearEnd })}`);
      }
    }

    const cur = sub.items.data[0];
    return json({
      hasSubscription: true,
      planPriceCents,
      renewalPriceCents: cur?.price?.unit_amount ?? null,
      interval: cur?.price?.recurring?.interval ?? "month",
      nextRenewalDate: isoDay(sub.trial_end && sub.trial_end > Date.now() / 1000 ? sub.trial_end : sub.current_period_end),
      endsOn: isoDay(sub.cancel_at),
      status: sub.status,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("owner-subscription-terms failed:", message);
    return json({ error: message }, 400);
  }
});
