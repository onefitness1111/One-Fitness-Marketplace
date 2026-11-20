// Owner sets a password for a client or a coach. Not deployed until you
// deploy this function. A coach must not call it: setting someone else's
// password is a way to take over that account, including the owner's.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const body = await req.json();
    const profileId = String(body.profileId ?? "").trim();
    const password = String(body.password ?? "");
    if (!profileId) throw new Error("Choose an account first.");
    if (password.length < 6) throw new Error("Use at least 6 characters.");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (caller?.role !== "owner") throw new Error("Only the owner can set a password.");

    const { data: target } = await admin.from("profiles").select("role").eq("id", profileId).maybeSingle();
    if (!target || (target.role !== "client" && target.role !== "coach")) {
      throw new Error("That account can't have its password set from here.");
    }
    if (profileId === user.id) throw new Error("Change your own password from your profile, not from here.");

    const { error } = await admin.auth.admin.updateUserById(profileId, { password });
    if (error) throw new Error(error.message || "Couldn't set that password.");

    console.log(`admin-set-password: owner ${user.id} set password for ${profileId} (${target.role})`);
    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("admin-set-password failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
