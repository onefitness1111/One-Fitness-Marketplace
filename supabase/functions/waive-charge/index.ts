// Owner-only: waives an early-termination-fee charge. Marks it waived
// rather than deleting it — the record that the fee was correctly
// assessed under the plan's cancellation policy stays intact, it's just
// no longer collected. Deployed WITH jwt verification; the owner-role
// check below is the actual authorization, same pattern as refund-charge.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { chargeId } = await req.json();
    if (!chargeId) throw new Error("chargeId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } }
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "owner") throw new Error("Only the owner can waive a fee.");

    const { data: charge, error: chargeErr } = await admin.from("charges").select("type, waived_at").eq("id", chargeId).maybeSingle();
    if (chargeErr) throw chargeErr;
    if (!charge) throw new Error("Charge not found.");
    if (charge.type !== "early_termination_fee") throw new Error("Only an early termination fee can be waived.");
    if (charge.waived_at) throw new Error("This fee was already waived.");

    const { error: updateErr } = await admin.from("charges")
      .update({ waived_at: new Date().toISOString(), waived_by: "owner" })
      .eq("id", chargeId);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("waive-charge failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
