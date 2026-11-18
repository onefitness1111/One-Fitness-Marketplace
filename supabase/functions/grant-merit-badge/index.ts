// Coach or owner awards a coach badge (PR, or a Gym Citizen check).
// Completing all 10 Gym Citizen checks also awards Gym Citizen itself.
// A new badge sends the client a push and an email.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncMeritBadgePoints } from "../_shared/meritBadgePoints.ts";
import { GYM_CITIZEN_SUB_BADGE_KEYS } from "../_shared/gymCitizenSubBadges.ts";
import { notifyBadgeEarned } from "../_shared/badgeNotify.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const COACH_AWARDABLE_KEYS = ["record_breaker", "gym_citizen", ...GYM_CITIZEN_SUB_BADGE_KEYS];

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { clientId, badgeKey, note } = await req.json();
    if (!clientId || !badgeKey) throw new Error("clientId and badgeKey are required");
    if (!COACH_AWARDABLE_KEYS.includes(badgeKey)) throw new Error("This badge can't be manually awarded.");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (caller?.role !== "coach" && caller?.role !== "owner") throw new Error("Only coaches and the owner can award badges.");

    const { data: existing } = await admin.from("merit_badges")
      .select("id").eq("client_id", clientId).eq("badge_key", badgeKey).is("revoked_at", null).maybeSingle();
    if (existing) {
      return new Response(JSON.stringify({ ok: true, alreadyEarned: true }), { headers: { ...CORS, "Content-Type": "application/json" } });
    }

    const { error: insertErr } = await admin.from("merit_badges").insert({
      client_id: clientId, badge_key: badgeKey, earned_method: "coach",
      granted_by_user_id: user.id, note: note ? String(note).trim() : null,
    });
    if (insertErr) {
      if (insertErr.code === "23505") {
        return new Response(JSON.stringify({ ok: true, alreadyEarned: true }), { headers: { ...CORS, "Content-Type": "application/json" } });
      }
      throw insertErr;
    }

    const awarded = [badgeKey];
    if (GYM_CITIZEN_SUB_BADGE_KEYS.includes(badgeKey)) {
      const { data: activeSubs } = await admin.from("merit_badges").select("badge_key")
        .eq("client_id", clientId).in("badge_key", GYM_CITIZEN_SUB_BADGE_KEYS).is("revoked_at", null);
      if ((activeSubs?.length || 0) >= GYM_CITIZEN_SUB_BADGE_KEYS.length) {
        const { data: existingParent } = await admin.from("merit_badges")
          .select("id").eq("client_id", clientId).eq("badge_key", "gym_citizen").is("revoked_at", null).maybeSingle();
        if (!existingParent) {
          const { error: parentErr } = await admin.from("merit_badges").insert({
            client_id: clientId, badge_key: "gym_citizen", earned_method: "coach",
            granted_by_user_id: user.id, note: "Completed all 10 Gym Citizen checks.",
          });
          if (parentErr && parentErr.code !== "23505") throw parentErr;
          if (!parentErr) awarded.push("gym_citizen");
        }
      }
    }

    await syncMeritBadgePoints(admin, clientId);
    for (const key of awarded) await notifyBadgeEarned(admin, clientId, key);
    return new Response(JSON.stringify({ ok: true, badgeKey, awarded }), { headers: { ...CORS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("grant-merit-badge failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS, "Content-Type": "application/json" } });
  }
});
