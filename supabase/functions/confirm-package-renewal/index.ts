// After the client confirms a package renewal in the payment sheet.
//
// Proposed. Not deployed until you deploy this function.
// Checks with Stripe that the payment succeeded, then sends one
// confirmation by phone notification, in the app, and by email.
// Calling it again for the same payment does not send a second one
// and does not charge again.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";
import { sendEmail } from "../_shared/sendEmail.ts";
import { EMAIL_SIGNOFF } from "../_shared/businessName.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

function money(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { paymentIntentId } = await req.json();
    if (!paymentIntentId || typeof paymentIntentId !== "string") throw new Error("Missing payment.");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const intent = await stripe.paymentIntents.retrieve(paymentIntentId);
    const meta = intent.metadata || {};
    if (meta.profile_id !== user.id) throw new Error("That payment is not yours.");
    if (meta.renewal_offer !== "discount" && meta.renewal_offer !== "full") {
      throw new Error("That payment is not a package renewal.");
    }
    if (intent.status !== "succeeded") throw new Error("That payment has not gone through yet.");

    const { data: row } = await admin
      .from("package_renewal_charges")
      .select("idempotency_key, confirmed_at, plan_id, enrollment_start, offer")
      .eq("payment_intent_id", intent.id)
      .maybeSingle();

    if (row?.confirmed_at) {
      return new Response(JSON.stringify({ ok: true, alreadyConfirmed: true }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    const amount = intent.amount_received || intent.amount || 0;
    if (row?.idempotency_key) {
      const { data: locked, error: updateErr } = await admin.from("package_renewal_charges").update({
        status: "succeeded",
        confirmed_at: new Date().toISOString(),
        amount_cents: amount,
      }).eq("idempotency_key", row.idempotency_key).is("confirmed_at", null).select("idempotency_key");
      if (updateErr) throw updateErr;
      if (!locked || locked.length === 0) {
        return new Response(JSON.stringify({ ok: true, alreadyConfirmed: true }), {
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        });
      }
    }

    const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", meta.plan_id).maybeSingle();
    const planName = String(planRow?.data?.name || "package");
    const title = "Renewal confirmed";
    const body = `Your ${planName} renewal went through. ${money(amount)} was charged to the card on file.`;

    const { error: noticeErr } = await admin.from("client_notices").insert({
      client_id: user.id,
      kind: "package_confirmed",
      plan_id: meta.plan_id || "",
      enrollment_start: meta.enrollment_start || null,
      title,
      body,
    });
    if (noticeErr && noticeErr.code !== "23505") console.error("renewal confirmation notice failed");

    await notifyProfile(admin, user.id, title, body, false);
    const { data: profile } = await admin.from("profiles").select("email, name").eq("id", user.id).maybeSingle();
    const email = String(profile?.email || "").trim();
    const first = String(profile?.name || "").trim().split(/\s+/)[0] || "there";
    if (email) {
      await sendEmail(
        email,
        "Your ONE Fitness renewal is confirmed",
        `Hi ${first},\n\nYour ${planName} renewal went through. ${money(amount)} was charged to the card on file. Your sessions will show in the app once the payment finishes processing.\n\n${EMAIL_SIGNOFF}`,
      );
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Could not confirm that renewal.";
    console.error("confirm-package-renewal failed");
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
