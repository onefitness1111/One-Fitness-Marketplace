// Starts freezes the owner already approved, once the 48-hour wait and the
// from-date have both passed. Pauses Stripe billing the same way an
// immediate owner freeze does.
//
// Proposed. Not deployed until you deploy this function.
// The app calls it when the owner opens Requests. A timer can call it too,
// with the header x-cron-secret set to the Vault secret apply_requests_cron.
// The password is not stored in this file or in an edge-function env var.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const admin = createClient(url, serviceKey);

    const cron = req.headers.get("x-cron-secret");
    const { data: secretRow, error: secretErr } = await admin.rpc("cron_vault_secret");
    if (secretErr) console.error("cron vault read failed");
    const expected = typeof secretRow === "string" ? secretRow : "";
    const cronOk = expected.length > 0 && cron === expected;
    if (!cronOk) {
      const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await authed.auth.getUser();
      if (!user) throw new Error("Not signed in.");
      const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (profile?.role !== "owner") throw new Error("Only the owner can apply freezes.");
    }

    const { data: due, error } = await admin.rpc("due_freeze_requests");
    if (error) throw error;
    const rows = Array.isArray(due) ? due : [];
    let applied = 0;

    for (const row of rows) {
      const clientId = String(row.clientId ?? "");
      const from = String(row.from ?? "");
      const to = String(row.to ?? "");
      if (!clientId || !to) continue;

      const { data: clientRow } = await admin.from("clients").select("stripe_subscription_id").eq("profile_id", clientId).maybeSingle();
      if (clientRow?.stripe_subscription_id) {
        const resumesAt = Math.floor(new Date(to + "T12:00:00Z").getTime() / 1000);
        await stripe.subscriptions.update(clientRow.stripe_subscription_id, {
          pause_collection: { behavior: "void", resumes_at: resumesAt },
        });
      }
      const { error: updateErr } = await admin.from("clients").update({
        membership_paused: true,
        membership_paused_at: from,
        membership_freeze_ends_at: to,
      }).eq("profile_id", clientId);
      if (updateErr) throw updateErr;

      await admin.rpc("mark_request_applied", { p_id: row.id, p_booking: null });
      await notifyProfile(
        admin,
        clientId,
        "Your membership freeze has started",
        `Your freeze is now in effect${to ? ` until ${to}` : ""}.`,
        true,
      );
      if (row.coachId) {
        await notifyProfile(
          admin,
          String(row.coachId),
          "A freeze you requested has started",
          `The freeze is now in effect${to ? ` until ${to}` : ""}.`,
          false,
        );
      }
      applied += 1;
    }

    return new Response(JSON.stringify({ ok: true, applied }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("apply-due-requests failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
