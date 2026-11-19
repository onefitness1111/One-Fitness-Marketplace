// Returns the caller's private calendar-feed URL, minting the token on first
// use. Separate from calendar-feed itself because the two have opposite auth
// models: this one identifies a real signed-in user, while the feed is fetched
// by Google with no session at all and is guarded by the token instead.
//
// Passing `regenerate: true` issues a new token, which immediately breaks every
// previously shared copy of the URL — that's the revoke path, for when someone
// has handed their link to the wrong person.
//
// Deploy with the login check left on:
//   supabase functions deploy get-calendar-link
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { regenerate = false } = await req.json().catch(() => ({}));

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: profile, error: readErr } = await admin.from("profiles")
      .select("calendar_token, role").eq("id", user.id).maybeSingle();
    if (readErr) throw readErr;
    if (profile?.role === "owner") {
      return new Response(JSON.stringify({ error: "The owner account does not have calendar sync." }), {
        status: 403,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    let token = profile?.calendar_token as string | null;
    if (!token || regenerate) {
      // Two UUIDs' worth of entropy, hex only so it survives being copied
      // through chat apps and pasted into Google's URL field intact.
      token = (crypto.randomUUID() + crypto.randomUUID()).replace(/-/g, "");
      const { error: writeErr } = await admin.from("profiles")
        .update({ calendar_token: token }).eq("id", user.id);
      if (writeErr) throw writeErr;
    }

    const base = (Deno.env.get("SUPABASE_URL") ?? "").replace(".supabase.co", ".functions.supabase.co");
    return new Response(
      JSON.stringify({ url: `${base}/calendar-feed?token=${token}` }),
      { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("get-calendar-link failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
