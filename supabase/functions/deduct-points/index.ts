// Owner-only general point removal — {clientId, amount, reason}. Distinct
// from void-points: this doesn't target one specific prior row (e.g. "took
// back 5 points as a no-show penalty"), it just removes points generally,
// FIFO-consuming whatever's currently oldest-and-live, same as a
// redemption would. Owner only — coaches have grant-points and
// void-points, never a general "take points away" power.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger } from "../_shared/pointsLedger.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId, amount, reason } = await req.json();
    if (!clientId) throw new Error("clientId is required");
    if (!Number.isInteger(amount) || amount <= 0) throw new Error("amount must be a positive whole number.");
    if (!reason || String(reason).trim().length < 5) throw new Error("reason must be at least 5 characters.");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "owner") throw new Error("Only the owner can deduct points.");

    const { data: allRows } = await admin.from("points_ledger").select("*").eq("client_id", clientId);
    const { balance } = replayLedger(allRows || []);
    if (amount > balance) throw new Error(`This client only has ${balance} points available — can't deduct ${amount}.`);

    const nowIso = new Date().toISOString();
    const { data: inserted, error: insertErr } = await admin.from("points_ledger").insert({
      client_id: clientId, amount: -amount, type: "deduct", source: "owner_deduction",
      granted_by_user_id: user.id, reason: String(reason).trim(), created_at: nowIso,
    }).select("id").single();
    if (insertErr) throw insertErr;

    return new Response(JSON.stringify({ ok: true, id: inserted.id }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("deduct-points failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
