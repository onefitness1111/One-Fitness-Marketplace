// Charges a client's saved card from a coach or the owner.
//
// The amount is the late fee ($15) or the short-notice fee ($25).
// The card is charged off-session. A bank check or a declined card comes
// back as needsCard so the app can ask for a new one. Coaches do not
// receive the billing address or the phone number in the answer.
//
// Deploy with the login check left on:
//   supabase functions deploy charge-client
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";
import { requireCoachPermission } from "../_shared/coachPermissions.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const FEES: Record<string, number> = { late: 1500, close: 2500, noshow: 2500 };
const LABELS: Record<string, string> = {
  late: "Late cancellation fee",
  close: "Short-notice cancellation fee",
  noshow: "No-show fee",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json();
    const clientId = String(body.clientId ?? "");
    const action = String(body.action ?? "preview");
    const kind = String(body.kind ?? "late");
    if (!clientId) throw new Error("Choose a client.");
    if (!FEES[kind]) throw new Error("Choose the late fee or the short-notice fee.");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const role = String(me?.role ?? "");
    const { data: clientRow } = await admin
      .from("clients")
      .select("stripe_customer_id")
      .eq("profile_id", clientId)
      .maybeSingle();
    if (!clientRow) throw new Error("That client was not found.");
    const allowed = role === "owner" || role === "coach";
    if (!allowed) throw new Error("Only a coach or the owner can charge a client.");
    // Charging a card is the owner's switch per coach. Saving a card ("setup") is billing access.
    await requireCoachPermission(admin, user.id, role, action === "setup" ? "billing_access" : "charge_fees");

    const secret = Deno.env.get("STRIPE_SECRET_KEY");
    if (!secret) throw new Error("Card payments aren't set up yet.");
    const stripe = new Stripe(secret, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
    const customerId = clientRow.stripe_customer_id as string | null;
    const card = customerId ? await defaultCard(stripe, customerId) : null;

    if (action === "preview") {
      return json({
        ok: true,
        lateCents: FEES.late,
        closeCents: FEES.close,
        card: card ? { brand: card.brand, last4: card.last4 } : null,
        needsAddress: Boolean(card && !card.hasAddress),
        hasCard: Boolean(card),
      });
    }

    if (action === "setup") {
      const customer = await ensureCustomer(stripe, admin, clientId, customerId);
      const ephemeralKey = await stripe.ephemeralKeys.create({ customer }, { apiVersion: "2024-06-20" });
      const setupIntent = await stripe.setupIntents.create({
        customer,
        payment_method_types: ["card"],
        usage: "off_session",
        metadata: { profile_id: clientId },
      });
      return json({
        ok: true,
        setupIntentClientSecret: setupIntent.client_secret,
        ephemeralKey: ephemeralKey.secret,
        customerId: customer,
        publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      });
    }

    const ledgerId = String(body.ledgerId ?? "");
    if (!card || (!card.hasAddress && !body.address)) {
      return await recordBalance(admin, clientId, kind, user.id, null, null, ledgerId);
    }
    if (body.address) {
      await stripe.paymentMethods.update(card.id, { billing_details: billing(body.address) });
      await stripe.customers.update(customerId!, {
        name: String(body.address.name ?? "") || undefined,
        address: stripeAddress(body.address),
      });
    }

    let intent: Stripe.PaymentIntent;
    try {
      intent = await stripe.paymentIntents.create({
        amount: FEES[kind],
        currency: "usd",
        customer: customerId!,
        payment_method: card.id,
        off_session: true,
        confirm: true,
        description: LABELS[kind],
        metadata: { client_id: clientId, fee_kind: kind },
      });
    } catch (e) {
      const err = e as { code?: string; payment_intent?: { id?: string } };
      if (err.payment_intent?.id) {
        try {
          await stripe.paymentIntents.cancel(err.payment_intent.id);
        } catch (_) { /* already closed */ }
      }
      return await recordBalance(admin, clientId, kind, user.id, err.payment_intent?.id ?? null, card.id, ledgerId, err.code ?? "card_declined");
    }
    if (intent.status !== "succeeded") {
      try {
        await stripe.paymentIntents.cancel(intent.id);
      } catch (_) { /* requires_action that cannot be finished off-session */ }
      return await recordBalance(admin, clientId, kind, user.id, intent.id, card.id, ledgerId, intent.status);
    }

    if (ledgerId) {
      await admin.rpc("settle_ledger_paid", {
        p_id: ledgerId,
        p_payment_intent: intent.id,
        p_payment_method: card.id,
      });
    }

    const { data: profile } = await admin.from("profiles").select("name").eq("id", clientId).maybeSingle();
    await admin.from("charges").insert({
      client_id: clientId,
      client_name: profile?.name ?? "",
      type: kind === "late" ? "late" : "noshow",
      date: new Date().toISOString().slice(0, 10),
      at: new Date().toISOString(),
      amount: FEES[kind] / 100,
      category: "fee",
      description: LABELS[kind],
      trainer_id: user.id,
      payment_method_id: card.id,
      stripe_payment_intent_id: intent.id,
    });
    const dollars = `$${(FEES[kind] / 100).toFixed(2)}`;
    await notifyProfile(admin, clientId, "Fee charged", `A ${dollars} ${LABELS[kind].toLowerCase()} was charged to your card.`, false);
    return json({
      ok: true,
      charged: true,
      amountCents: FEES[kind],
      card: { brand: card.brand, last4: card.last4 },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("charge-client failed");
    return json({ error: message }, 400);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

// No card, a decline, or a bank check that was not finished. The fee is
// recorded either way. A second try for the same ledger row does not add it again.
// deno-lint-ignore no-explicit-any
async function recordBalance(
  admin: any,
  clientId: string,
  kind: string,
  createdBy: string,
  paymentIntentId: string | null,
  paymentMethodId: string | null,
  ledgerId: string,
  code?: string,
) {
  if (ledgerId) {
    const { data: row } = await admin.from("clients").select("balance_cents").eq("profile_id", clientId).maybeSingle();
    return json({
      ok: false,
      balanceRecorded: true,
      alreadyRecorded: true,
      optionalCard: true,
      ledgerId,
      balanceCents: row?.balance_cents ?? null,
      amountCents: FEES[kind],
      code: code ?? null,
    });
  }
  const feeType = kind === "close" ? "close" : kind === "noshow" ? "noshow" : "late";
  const { data: recorded, error } = await admin.rpc("record_unpaid_fee", {
    p_client: clientId,
    p_type: feeType,
    p_amount_cents: FEES[kind],
    p_booking: null,
    p_created_by: createdBy,
    p_stripe_payment_intent: paymentIntentId,
    p_stripe_payment_method: paymentMethodId,
  });
  if (error) throw new Error(error.message);
  const owed = Math.abs(Number(recorded?.balanceCents ?? FEES[kind]));
  const dollars = `$${(owed / 100).toFixed(2)}`;
  await notifyProfile(
    admin,
    clientId,
    "Outstanding balance",
    `You have an outstanding balance of ${dollars}. Please pay your balance to book sessions.`,
    false,
  );
  return json({
    ok: false,
    balanceRecorded: true,
    optionalCard: true,
    ledgerId: recorded?.ledgerId ?? null,
    balanceCents: recorded?.balanceCents ?? null,
    amountCents: FEES[kind],
    code: code ?? null,
  });
}

async function defaultCard(stripe: Stripe, customerId: string) {
  const customer = await stripe.customers.retrieve(customerId);
  if ("deleted" in customer && customer.deleted) return null;
  const fallback = (customer as Stripe.Customer).invoice_settings?.default_payment_method;
  const defaultId = typeof fallback === "string" ? fallback : fallback?.id;
  const list = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 10 });
  const pm = list.data.find((item) => item.id === defaultId) ?? list.data[0];
  if (!pm) return null;
  const line1 = pm.billing_details?.address?.line1 ?? "";
  return {
    id: pm.id,
    brand: pm.card?.brand ?? "card",
    last4: pm.card?.last4 ?? "",
    hasAddress: line1.trim().length > 0,
  };
}

function billing(address: Record<string, string>) {
  return { name: address.name, address: stripeAddress(address) };
}

function stripeAddress(address: Record<string, string>) {
  return {
    line1: address.line1,
    line2: address.line2 || undefined,
    city: address.city,
    state: address.state,
    postal_code: address.postal_code,
    country: address.country || "US",
  };
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
