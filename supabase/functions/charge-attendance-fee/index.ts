// Charges the fee after a coach marks late cancel or no-show.
// Early cancel is free. Late cancel follows the clock and gives the session
// back. A no-show is $25 and the session is used (the attendance mark
// already did that; this function does not change the session count).
//
// Proposed. Not deployed until you deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { collectSessionFee } from "../_shared/sessionFee.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const body = await req.json();
    const bookingId = body.bookingId;
    if (!bookingId) throw new Error("bookingId is required");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (me?.role !== "owner" && me?.role !== "coach") {
      throw new Error("Only a coach or the owner can mark attendance.");
    }

    const result = await collectSessionFee(admin, bookingId, "attendance", body.skipNotice === true);
    return new Response(JSON.stringify(result), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
