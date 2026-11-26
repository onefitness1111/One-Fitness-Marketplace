// Saves a billing address for a client and copies it onto their Stripe customer.
//
// The client, the owner, or any coach may call it. Clients are not assigned
// to a coach. The answer is only whether an address is now on file. The
// street is not returned.
// Deploy with the login check left on:
//   supabase functions deploy save-billing-address
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCoachPermission } from "../_shared/coachPermissions.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json();
    const clientId = String(body.clientId ?? "");
    const address = body.address ?? {};
    if (!clientId) throw new Error("Choose a client.");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const { data: clientRow } = await admin
      .from("clients")
      .select("stripe_customer_id")
      .eq("profile_id", clientId)
      .maybeSingle();
    const role = me?.role ?? "";
    const allowed = user.id === clientId || role === "owner" || role === "coach";
    if (!allowed) throw new Error("Not allowed to update that billing address.");

    // A coach may enter the first address and may not replace one. The
    // answer stays a yes/no. The street is not sent back.
    if (role === "coach" && user.id !== clientId) {
      await requireCoachPermission(admin, user.id, role, "billing_access");
      const { data: existing } = await admin.from("clients").select("billing_address").eq("profile_id", clientId).maybeSingle();
      const current = existing?.billing_address as { line1?: string } | null;
      if (String(current?.line1 ?? "").trim() !== "") {
        throw new Error("Only the owner can change an address that's already on file.");
      }
    }

    const { error } = await admin.rpc("set_client_billing_address", { p_client: clientId, p_address: address });
    if (error) throw new Error(error.message);

    const customerId = clientRow?.stripe_customer_id as string | undefined;
    const secret = Deno.env.get("STRIPE_SECRET_KEY");
    if (customerId && secret) {
      const stripe = new Stripe(secret, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
      await stripe.customers.update(customerId, {
        name: String(address.name ?? "") || undefined,
        address: {
          line1: String(address.line1 ?? ""),
          line2: String(address.line2 ?? "") || undefined,
          city: String(address.city ?? ""),
          state: String(address.state ?? ""),
          postal_code: String(address.postal_code ?? ""),
          country: String(address.country ?? "US"),
        },
      });
    }
    return new Response(JSON.stringify({ ok: true, billingOnFile: true }), {
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
