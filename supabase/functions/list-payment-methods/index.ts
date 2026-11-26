// Saved cards and bank accounts. A client sees their own. The owner can open
// a client's, and so can any coach. Clients are not assigned to a coach.
// The street address is not in this response.
//
// Not deployed until you deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCoachPermission } from "../_shared/coachPermissions.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { action, id, clientId } = await req.json().catch(() => ({}));

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    let targetId = user.id;
    if (clientId && clientId !== user.id) targetId = clientId;
    const { data: clientRow } = await admin.from("clients")
      .select("stripe_customer_id, stripe_subscription_id")
      .eq("profile_id", targetId)
      .maybeSingle();
    if (targetId !== user.id) {
      const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      const role = me?.role ?? "";
      const allowed = role === "owner" || role === "coach";
      if (!allowed) throw new Error("Not allowed to see or change that client's payment methods.");
      await requireCoachPermission(admin, user.id, role, "billing_access");
    }
    const customerId = clientRow?.stripe_customer_id as string | null;

    const secret = Deno.env.get("STRIPE_SECRET_KEY");
    if (!customerId || !secret) return json({ methods: [] });

    const stripe = new Stripe(secret, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });

    let defaultId: string | null = null;
    let subscriptionActive = false;
    if (clientRow?.stripe_subscription_id) {
      try {
        const sub = await stripe.subscriptions.retrieve(clientRow.stripe_subscription_id);
        subscriptionActive = sub.status !== "canceled" && sub.status !== "incomplete_expired";
        defaultId = typeof sub.default_payment_method === "string" ? sub.default_payment_method : sub.default_payment_method?.id ?? null;
      } catch (_) { /* cancelled or missing subscription */ }
    }

    if (action === "remove") {
      if (typeof id !== "string" || !id) throw new Error("id is required");
      const pm = await stripe.paymentMethods.retrieve(id);
      if (pm.customer !== customerId) throw new Error("That payment method isn't on your account.");
      if (subscriptionActive && id === defaultId) {
        throw new Error("This is the card your membership renews on, so it can't be removed while the membership is active.");
      }
      await stripe.paymentMethods.detach(id);
    }
    if (!defaultId) {
      const customer = await stripe.customers.retrieve(customerId);
      if (!("deleted" in customer && customer.deleted)) {
        const d = (customer as Stripe.Customer).invoice_settings?.default_payment_method;
        defaultId = typeof d === "string" ? d : d?.id ?? null;
      }
    }

    const list = await stripe.paymentMethods.list({ customer: customerId, limit: 20 });
    const methods = list.data
      .filter((m) => m.type === "card" || m.type === "us_bank_account")
      .map((m) => m.type === "card"
        ? {
          id: m.id,
          type: "card",
          brand: m.card?.brand ?? "card",
          last4: m.card?.last4 ?? "",
          expMonth: m.card?.exp_month ?? null,
          expYear: m.card?.exp_year ?? null,
          isDefault: m.id === defaultId,
        }
        : {
          id: m.id,
          type: "bank",
          brand: m.us_bank_account?.bank_name ?? "Bank account",
          last4: m.us_bank_account?.last4 ?? "",
          expMonth: null,
          expYear: null,
          isDefault: m.id === defaultId,
        });
    methods.sort((a, b) => Number(b.isDefault) - Number(a.isDefault));
    return json({ methods });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("list-payment-methods failed:", message);
    return json({ error: message }, 400);
  }
});
