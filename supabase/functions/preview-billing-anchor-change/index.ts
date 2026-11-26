// Billing Cycle Anchor Date spec §3 — "Show the owner a preview of the
// proration/next-charge date and amount before confirming the change."
// Pure read-only preview: never writes anything, to Stripe or to Supabase
// — the owner can call this as many times as they want while picking a
// date, and only change-billing-anchor/index.ts (a separate function)
// actually applies anything. Owner-only, mirrors delete-coach-account's
// role check.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

// The next real calendar date [day] falls on, strictly after [from] — e.g.
// asking for day 15 on the 20th of the month rolls to next month's 15th,
// never today or a date already past. Days are capped at 1-28 by the
// caller precisely so this never has to reason about "the 30th in
// February" — every month has a 28th.
function nextOccurrenceOfDay(day: number, from: Date): Date {
  const y = from.getUTCFullYear();
  const m = from.getUTCMonth();
  const candidate = new Date(Date.UTC(y, m, day, 0, 0, 0));
  return candidate.getTime() > from.getTime() ? candidate : new Date(Date.UTC(y, m + 1, day, 0, 0, 0));
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId, newAnchorDay } = await req.json();
    if (!clientId) throw new Error("clientId is required");
    const day = Number(newAnchorDay);
    if (!Number.isInteger(day) || day < 1 || day > 28) throw new Error("newAnchorDay must be a whole number from 1 to 28.");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "owner") throw new Error("Only the owner can change a client's billing date.");

    const { data: clientRow } = await admin.from("clients").select("stripe_subscription_id, billing_anchor_day").eq("profile_id", clientId).maybeSingle();
    if (!clientRow) throw new Error("That client no longer exists.");

    if (!clientRow.stripe_subscription_id) {
      return new Response(JSON.stringify({
        ok: true,
        hasActiveSubscription: false,
        message: "This client has no active Stripe subscription on file — there's nothing to prorate. The new date will only take effect if/when they start a subscription.",
      }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const target = nextOccurrenceOfDay(day, new Date());
    const targetTimestamp = Math.floor(target.getTime() / 1000);

    const preview = await stripe.invoices.createPreview({
      subscription: clientRow.stripe_subscription_id,
      subscription_details: {
        billing_cycle_anchor: targetTimestamp,
        proration_behavior: "create_prorations",
      },
    });

    return new Response(JSON.stringify({
      ok: true,
      hasActiveSubscription: true,
      proratedAmountCents: preview.total,
      currency: preview.currency,
      nextChargeDate: target.toISOString().slice(0, 10),
      currentAnchorDay: clientRow.billing_anchor_day,
    }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("preview-billing-anchor-change failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
