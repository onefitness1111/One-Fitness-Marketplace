// Billing Cycle Anchor Date spec §3/§4 — actually applies a per-client
// anchor-day override: updates the live Stripe subscription's billing
// cycle (with proration, same mechanism/reasoning as change-membership-
// plan's immediate-timing branch), persists clients.billing_anchor_day,
// and writes one client_billing_anchor_history row for support/dispute
// purposes. Owner-only. Rate-limited to once per 90 days per client (the
// spec's own suggested "once per quarter" cadence) to prevent
// billing-cycle gaming — checked against this table's own history, no
// separate counter needed.
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

const NINETY_DAYS_MS = 1000 * 60 * 60 * 24 * 90;

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

    const { data: lastChange } = await admin.from("client_billing_anchor_history")
      .select("changed_at").eq("client_id", clientId).order("changed_at", { ascending: false }).limit(1).maybeSingle();
    if (lastChange && Date.now() - new Date(lastChange.changed_at).getTime() < NINETY_DAYS_MS) {
      const nextAllowed = new Date(new Date(lastChange.changed_at).getTime() + NINETY_DAYS_MS);
      throw new Error(`This client's billing date was already changed within the last 90 days — the next change is allowed on ${nextAllowed.toISOString().slice(0, 10)}.`);
    }

    const oldValue = clientRow.billing_anchor_day ?? null;
    let proratedAmountCents: number | null = null;
    let nextChargeDate: string | null = null;

    if (clientRow.stripe_subscription_id) {
      const target = nextOccurrenceOfDay(day, new Date());
      const targetTimestamp = Math.floor(target.getTime() / 1000);
      nextChargeDate = target.toISOString().slice(0, 10);

      // Re-preview immediately before applying, purely to capture the
      // amount for the history record — the actual charge Stripe generates
      // moments later from the update below should match this closely,
      // since nothing about the subscription changes in between.
      try {
        const preview = await stripe.invoices.createPreview({
          subscription: clientRow.stripe_subscription_id,
          subscription_details: { billing_cycle_anchor: targetTimestamp, proration_behavior: "create_prorations" },
        });
        proratedAmountCents = preview.total;
      } catch (previewErr) {
        console.error("change-billing-anchor: preview-for-history failed (proceeding with the change anyway):", previewErr instanceof Error ? previewErr.message : String(previewErr));
      }

      await stripe.subscriptions.update(clientRow.stripe_subscription_id, {
        billing_cycle_anchor: targetTimestamp,
        proration_behavior: "create_prorations",
      });
    }

    const { error: updateErr } = await admin.from("clients").update({ billing_anchor_day: day }).eq("profile_id", clientId);
    if (updateErr) throw updateErr;

    const { error: historyErr } = await admin.from("client_billing_anchor_history").insert({
      client_id: clientId,
      old_value: oldValue,
      new_value: day,
      changed_by: user.id,
      prorated_amount_cents: proratedAmountCents,
      next_charge_date: nextChargeDate,
    });
    if (historyErr) throw historyErr;

    console.log(`change-billing-anchor: ${user.id} changed ${clientId}'s billing anchor ${oldValue ?? "(unset)"} -> ${day}`);
    return new Response(JSON.stringify({ ok: true, proratedAmountCents, nextChargeDate }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("change-billing-anchor failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
