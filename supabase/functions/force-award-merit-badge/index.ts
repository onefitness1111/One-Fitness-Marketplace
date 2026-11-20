// Owner-only. Writes the badge even when the rules do not match, and marks
// it earned_method "force" so the nightly sweep will not take it away.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncMeritBadgePoints } from "../_shared/meritBadgePoints.ts";
import { notifyBadgeEarned } from "../_shared/badgeNotify.ts";
import { BADGE_NAMES } from "../_shared/badgeRules.mjs";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { clientId, badgeKey, note } = await req.json();
    if (!clientId || !badgeKey) throw new Error("clientId and badgeKey are required");
    if (badgeKey === "first_session") {
      return new Response(JSON.stringify({ ok: true, alreadyEarned: true, awarded: [] }), {
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    if (!(badgeKey in BADGE_NAMES)) throw new Error("Unknown badge key.");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (caller?.role !== "owner") throw new Error("Only the owner can force-assign a badge.");

    const { data: existing } = await admin.from("merit_badges")
      .select("id").eq("client_id", clientId).eq("badge_key", badgeKey).is("revoked_at", null).maybeSingle();
    if (existing) {
      return new Response(JSON.stringify({ ok: true, alreadyEarned: true }), { headers: { ...CORS, "Content-Type": "application/json" } });
    }

    const { error } = await admin.from("merit_badges").insert({
      client_id: clientId,
      badge_key: badgeKey,
      earned_method: "force",
      granted_by_user_id: user.id,
      note: note ? String(note).trim() : null,
    });
    if (error) {
      if (error.code === "23505") {
        return new Response(JSON.stringify({ ok: true, alreadyEarned: true }), { headers: { ...CORS, "Content-Type": "application/json" } });
      }
      throw error;
    }
    await syncMeritBadgePoints(admin, clientId);
    await notifyBadgeEarned(admin, clientId, badgeKey);
    return new Response(JSON.stringify({ ok: true, badgeKey, awarded: [badgeKey] }), { headers: { ...CORS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("force-award-merit-badge failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS, "Content-Type": "application/json" } });
  }
});
