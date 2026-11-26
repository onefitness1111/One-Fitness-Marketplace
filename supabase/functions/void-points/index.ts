// Voids one specific prior earn/grant row — {ledgerRowId, reason}. Distinct
// from deduct-points: this cancels a SPECIFIC row (e.g. "that grant was a
// mistake"), not a general point removal. Only ever removes what's still
// actually remaining on that row (replayLedger, FIFO-aware) — if a client
// already spent some or all of it via a redemption, this can't claw that
// back, only what's left.
//
// Authorization: the SAME coach who made a grant can void it themselves
// within 24h (self-correcting a fat-fingered grant); after that, or for
// any row a coach didn't personally grant (including automatic `earn`
// rows), only the owner can void it.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger } from "../_shared/pointsLedger.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TWENTY_FOUR_HOURS_MS = 1000 * 60 * 60 * 24;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { ledgerRowId, reason } = await req.json();
    if (!ledgerRowId) throw new Error("ledgerRowId is required");
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
    const role = callerProfile?.role;
    if (role !== "coach" && role !== "owner") throw new Error("Only coaches and owners can void points.");

    const { data: target } = await admin.from("points_ledger").select("*").eq("id", ledgerRowId).maybeSingle();
    if (!target) throw new Error("Ledger row not found.");
    if (target.type !== "earn" && target.type !== "grant") throw new Error("Only an earn or grant row can be voided.");

    if (role !== "owner") {
      const isOwnRecentGrant = target.type === "grant" && target.granted_by_user_id === user.id &&
        Date.now() - new Date(target.created_at).getTime() <= TWENTY_FOUR_HOURS_MS;
      if (!isOwnRecentGrant) throw new Error("Coaches can only void their own grants within 24 hours. Ask the owner to void this one.");
    }

    const { data: allRows } = await admin.from("points_ledger").select("*").eq("client_id", target.client_id);
    const { lots } = replayLedger(allRows || []);
    const lot = lots.find((l) => l.id === ledgerRowId);
    const remaining = lot?.remaining || 0;
    if (remaining <= 0) throw new Error("This row has already been fully redeemed or voided — nothing left to void.");

    const nowIso = new Date().toISOString();
    const { data: inserted, error: insertErr } = await admin.from("points_ledger").insert({
      client_id: target.client_id, amount: -remaining, type: "void", source: "void_grant",
      voided_by_ledger_id: ledgerRowId, granted_by_user_id: user.id, reason: String(reason).trim(),
      created_at: nowIso,
    }).select("id").single();
    if (insertErr) throw insertErr;

    return new Response(JSON.stringify({ ok: true, id: inserted.id, voidedAmount: remaining }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("void-points failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
