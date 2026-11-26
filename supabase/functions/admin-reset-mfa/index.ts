// Lets the owner clear a locked-out staff member's two-factor factors so
// they can sign back in with just their password and re-enroll — without
// this, a coach who loses their authenticator app has no way back in at
// all (Supabase Auth requires completing MFA to reach aal2, and there's no
// self-serve "I lost my device" recovery built into the app). Uses the
// GoTrue Admin REST API directly (not a supabase-js admin.mfa wrapper,
// which isn't reliably present across supabase-js versions) — documented
// at https://supabase.com/docs/reference/auth-admin-api. Deployed WITH jwt
// verification; the owner-role check below is the actual authorization,
// same pattern as create-checkout-session. See supabase/MFA_SETUP.md.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { userId } = await req.json();
    if (!userId) throw new Error("userId is required");

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const authedClient = createClient(
      SUPABASE_URL,
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } }
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: callerProfile, error: profileErr } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (profileErr) throw profileErr;
    if (callerProfile?.role !== "owner") throw new Error("Only the owner can reset another account's two-factor authentication.");

    const adminHeaders = { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY };
    const lookupRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, { headers: adminHeaders });
    if (!lookupRes.ok) throw new Error("Couldn't look up that account.");
    const targetUser = await lookupRes.json();
    const factors = targetUser.factors || [];

    for (const factor of factors) {
      const delRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}/factors/${factor.id}`, {
        method: "DELETE",
        headers: adminHeaders,
      });
      if (!delRes.ok) throw new Error(`Couldn't remove one of their factors (${factor.id}). Try again, or clear it from the Supabase Dashboard directly.`);
    }

    console.log(`admin-reset-mfa: owner ${user.id} cleared ${factors.length} factor(s) for ${userId}`);
    return new Response(JSON.stringify({ ok: true, removed: factors.length }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("admin-reset-mfa failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
