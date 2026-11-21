// Takes the cancel fee while the booking still exists.
// Outside 12 hours: nothing. Inside 12 hours: $15. Inside 4 hours: $25.
// The session is not used. The client is told either way when money moves.
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
    const { bookingId } = await req.json();
    if (!bookingId) throw new Error("bookingId is required");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: booking } = await admin.from("bookings").select("client_id, trainer_id").eq("id", bookingId).maybeSingle();
    if (!booking) throw new Error("That booking is already gone.");
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const role = me?.role ?? "";
    const allowed = user.id === booking.client_id || role === "owner" || role === "coach";
    if (!allowed) throw new Error("You can't cancel that session.");

    const result = await collectSessionFee(admin, bookingId, "cancel", false);
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
