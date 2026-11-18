// Checks a Merit Badge and writes merit_badges when the client qualifies.
// Also accepts a bundle (after_session, after_habit, after_photo,
// after_measurement, after_workout, after_food) so the app can ask once
// when something just happened.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { runBadgeEvent } from "../_shared/badgeEligibility.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json();
    const clientId = body?.clientId;
    const badgeKey = body?.badgeKey;
    const sourceRefId = body?.sourceRefId ?? null;
    if (!clientId || !badgeKey) throw new Error("clientId and badgeKey are required");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const isSelf = user.id === clientId;
    const isStaff = caller && ["owner", "coach"].includes(caller.role);
    if (!isSelf && !isStaff) throw new Error("Not authorized for this client.");

    const result = await runBadgeEvent(admin, clientId, badgeKey, sourceRefId);
    if (result.awarded.length) {
      return new Response(JSON.stringify({ ok: true, badgeKey: result.awarded[0], awarded: result.awarded }), {
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    if (result.reason && !String(badgeKey).startsWith("after_")) {
      return new Response(JSON.stringify({ ok: false, reason: result.reason }), {
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ ok: true, alreadyEarned: true, awarded: [] }), {
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("award-merit-badge failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
