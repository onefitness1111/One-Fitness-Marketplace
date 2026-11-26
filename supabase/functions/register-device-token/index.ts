// Called once whenever the app gets a fresh FCM token (first launch after
// notification permission is granted, or whenever Firebase rotates the
// token — the Flutter side listens for both). Upserts by token, not by
// profile, so the same physical device switching between two accounts on
// this app (a coach testing their own client login, say) doesn't leave a
// stale row still pointing a push at the wrong person.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { token, platform } = await req.json();
    if (!token) throw new Error("token is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { error } = await admin.from("device_tokens").upsert(
      { token, profile_id: user.id, platform: platform === "ios" ? "ios" : "android", updated_at: new Date().toISOString() },
      { onConflict: "token" },
    );
    if (error) throw error;

    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("register-device-token failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
