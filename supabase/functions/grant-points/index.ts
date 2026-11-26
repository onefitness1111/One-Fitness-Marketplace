// Coach/owner discretionary point grant — {clientId, amount: 1|3|5, reason}.
// Points a coach or owner can hand out for anything not covered by an
// automatic earning event (extra effort, a good attitude, whatever). Capped
// at 5 points/coach/client/calendar-month so a coach can't just hand out
// unlimited discounts; the owner is exempt from that cap. There is no RLS
// insert policy on points_ledger at all (see schema_phase16_rewards.sql) —
// this function, running as the service role, is the ONLY way a grant row
// can ever be written, which is what makes the cap and the reason
// requirement actually unbypassable from devtools.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 30 * 6;
const MONTHLY_COACH_CAP = 5;
const ALLOWED_AMOUNTS = [1, 3, 5];

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId, amount, reason } = await req.json();
    if (!clientId) throw new Error("clientId is required");
    if (!ALLOWED_AMOUNTS.includes(amount)) throw new Error("amount must be 1, 3, or 5.");
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
    if (role !== "coach" && role !== "owner") throw new Error("Only coaches and owners can grant points.");

    if (role === "coach") {
      const monthStart = new Date();
      monthStart.setUTCDate(1);
      monthStart.setUTCHours(0, 0, 0, 0);
      const { data: monthGrants } = await admin.from("points_ledger")
        .select("amount")
        .eq("client_id", clientId)
        .eq("type", "grant")
        .eq("granted_by_user_id", user.id)
        .gte("created_at", monthStart.toISOString());
      const grantedThisMonth = (monthGrants || []).reduce((sum: number, r: any) => sum + r.amount, 0);
      if (grantedThisMonth + amount > MONTHLY_COACH_CAP) {
        throw new Error(`This would exceed the ${MONTHLY_COACH_CAP}-point monthly cap for this client (already granted ${grantedThisMonth} this month).`);
      }
    }

    const nowIso = new Date().toISOString();
    const { data: inserted, error: insertErr } = await admin.from("points_ledger").insert({
      client_id: clientId, amount, type: "grant", source: "discretionary_grant",
      granted_by_user_id: user.id, reason: String(reason).trim(),
      earned_at: nowIso, expires_at: new Date(Date.now() + SIX_MONTHS_MS).toISOString(), created_at: nowIso,
    }).select("id").single();
    if (insertErr) throw insertErr;

    return new Response(JSON.stringify({ ok: true, id: inserted.id, amount }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("grant-points failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
