// Coach/owner-only badge removal — {badgeId}. Only ever allowed for a
// badge whose earned_method is "coach" (Record Breaker, Gym Citizen) —
// automatic badges are system-computed and can never be revoked here,
// re-verified server-side regardless of what the UI shows. Soft-delete:
// sets revoked_at/revoked_by_user_id rather than deleting the row, so
// MeritBadgesTab can show it in "History" instead of losing all record of
// it. See schema_phase21_badge_revocation.sql for the partial unique index
// that lets the same badge_key be earned/awarded again later as a fresh
// row once revoked.
//
// Also resyncs points_ledger's live Merit Badge points (4+ active badges
// = 3 points each, recalculated on every change — see
// supabase/functions/_shared/meritBadgePoints.ts) since removing a
// coach-awarded badge can drop the client's active count below that
// threshold or otherwise change the total.
//
// Gym Citizen sub-badge cascade: revoking one of the 10 sub-badges (see
// GYM_CITIZEN_SUB_BADGE_KEYS) that drops the client's active-sub-badge
// count below 10 also revokes the parent "gym_citizen" badge if it's
// currently active — mirrors grant-merit-badge's award-side cascade.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncMeritBadgePoints } from "../_shared/meritBadgePoints.ts";
import { GYM_CITIZEN_SUB_BADGE_KEYS } from "../_shared/gymCitizenSubBadges.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { badgeId } = await req.json();
    if (!badgeId) throw new Error("badgeId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "coach" && callerProfile?.role !== "owner") throw new Error("Only coaches and owners can remove badges.");

    const { data: badge } = await admin.from("merit_badges").select("id, client_id, badge_key, earned_method, revoked_at").eq("id", badgeId).maybeSingle();
    if (!badge) throw new Error("Badge not found.");
    if (badge.earned_method !== "coach") throw new Error("Only coach-awarded badges can be removed — automatic badges are system-computed.");
    if (badge.revoked_at) {
      return new Response(JSON.stringify({ ok: true, alreadyRevoked: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const { error: updateErr } = await admin.from("merit_badges")
      .update({ revoked_at: new Date().toISOString(), revoked_by_user_id: user.id })
      .eq("id", badgeId);
    if (updateErr) throw updateErr;

    if (GYM_CITIZEN_SUB_BADGE_KEYS.includes(badge.badge_key)) {
      const { data: activeSubs } = await admin.from("merit_badges").select("badge_key")
        .eq("client_id", badge.client_id).in("badge_key", GYM_CITIZEN_SUB_BADGE_KEYS).is("revoked_at", null);
      if ((activeSubs?.length || 0) < GYM_CITIZEN_SUB_BADGE_KEYS.length) {
        const { data: parent } = await admin.from("merit_badges")
          .select("id").eq("client_id", badge.client_id).eq("badge_key", "gym_citizen").is("revoked_at", null).maybeSingle();
        if (parent) {
          await admin.from("merit_badges")
            .update({ revoked_at: new Date().toISOString(), revoked_by_user_id: user.id })
            .eq("id", parent.id);
        }
      }
    }

    await syncMeritBadgePoints(admin, badge.client_id);

    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("revoke-merit-badge failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
