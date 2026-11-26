// Posts an `expire` row for every lot whose 6-month clock has passed but
// hasn't been reconciled yet — {clientId} (defaults to the caller). Called
// opportunistically (Rewards tab load for clients, Points tab load for
// staff) since this app has no cron anywhere; safe to call as often as
// anyone likes, since replayLedger only ever finds genuinely-expired,
// still-remaining lots (already-spent or already-expired amounts are
// excluded by construction).
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
    const body = await req.json().catch(() => ({}));

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const clientId = body.clientId || user.id;
    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const isSelf = user.id === clientId;
    const isStaff = callerProfile && ["owner", "coach"].includes(callerProfile.role);
    if (!isSelf && !isStaff) throw new Error("Not authorized for this client.");

    const { data: allRows } = await admin.from("points_ledger").select("*").eq("client_id", clientId);
    const { pendingExpiry } = replayLedger(allRows || []);

    if (!pendingExpiry.length) {
      return new Response(JSON.stringify({ ok: true, expired: 0 }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const nowIso = new Date().toISOString();
    const rows = pendingExpiry.map((lot) => ({
      client_id: clientId, amount: -lot.remaining, type: "expire", source: "expiry_sweep",
      voided_by_ledger_id: lot.id, created_at: nowIso,
    }));
    const { error: insertErr } = await admin.from("points_ledger").insert(rows);
    if (insertErr) throw insertErr;

    return new Response(JSON.stringify({ ok: true, expired: rows.length }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("sweep-expired-points failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
