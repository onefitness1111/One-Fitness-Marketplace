// Opportunistic 6-month expiry sweep for Gym Citizen's 10 sub-badges —
// {clientId}. Unlike Progress Tracker's sub-badges (which have a live data
// signal to re-derive eligibility from, see award-merit-badge), a coach
// checking off "Re-Rack" is a point-in-time judgment call with nothing to
// re-derive — so these need a genuine stored-timestamp expiry instead,
// checked opportunistically since this app has no cron (same "whoever's
// looking triggers it" doctrine as every other automatic badge check).
//
// Any sub-badge whose earned_at is more than 6 months old gets revoked
// (revoked_by_user_id left null — a SYSTEM expiry, not a coach's own
// action, same convention award-merit-badge already uses for automatic
// removals). If that drops the client's active sub-badge count below 10,
// the parent "gym_citizen" badge is revoked too, mirroring the exact same
// cascade grant-merit-badge/revoke-merit-badge already do when a coach
// directly checks/unchecks a sub-badge.
//
// Self-or-staff auth (like award-merit-badge) — a client's own dashboard
// load is a legitimate trigger for this, even though the underlying rows
// are earned_method:"coach", because the ACTION here (time-based expiry)
// is system-determined, not a judgment call the caller could fake.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncMeritBadgePoints } from "../_shared/meritBadgePoints.ts";
import { GYM_CITIZEN_SUB_BADGE_KEYS } from "../_shared/gymCitizenSubBadges.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 30 * 6;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId } = await req.json();
    if (!clientId) throw new Error("clientId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const isSelf = user.id === clientId;
    const isStaff = callerProfile && ["owner", "coach"].includes(callerProfile.role);
    if (!isSelf && !isStaff) throw new Error("Not authorized for this client.");

    const { data: activeSubs } = await admin.from("merit_badges")
      .select("id, earned_at").eq("client_id", clientId).in("badge_key", GYM_CITIZEN_SUB_BADGE_KEYS).is("revoked_at", null);

    const now = Date.now();
    const expired = (activeSubs || []).filter((r: { earned_at: string }) => now - new Date(r.earned_at).getTime() > SIX_MONTHS_MS);

    if (!expired.length) {
      return new Response(JSON.stringify({ ok: true, expiredCount: 0 }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const nowIso = new Date().toISOString();
    const { error: expireErr } = await admin.from("merit_badges")
      .update({ revoked_at: nowIso, revoked_by_user_id: null })
      .in("id", expired.map((r: { id: string }) => r.id));
    if (expireErr) throw expireErr;

    const remainingActive = (activeSubs || []).length - expired.length;
    let gymCitizenRevoked = false;
    if (remainingActive < GYM_CITIZEN_SUB_BADGE_KEYS.length) {
      const { data: parent } = await admin.from("merit_badges")
        .select("id").eq("client_id", clientId).eq("badge_key", "gym_citizen").is("revoked_at", null).maybeSingle();
      if (parent) {
        await admin.from("merit_badges").update({ revoked_at: nowIso, revoked_by_user_id: null }).eq("id", parent.id);
        gymCitizenRevoked = true;
      }
    }

    await syncMeritBadgePoints(admin, clientId);

    return new Response(JSON.stringify({ ok: true, expiredCount: expired.length, gymCitizenRevoked }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("check-gym-citizen-expiry failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
