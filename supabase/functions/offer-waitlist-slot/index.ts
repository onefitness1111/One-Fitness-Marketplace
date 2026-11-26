// Offers a freed session slot to the people waiting for it.
//
// Called when a booking is cancelled, whenever an offer is declined, and
// every 15 minutes by waitlist-sweep. Runs server-side because the client
// cancelling a booking must not be the one deciding who gets it next, and
// because the offer goes out by push, SMS and email.
//
// Offers cascade rather than queue strictly: each person has four hours to
// answer, and every two hours the next person in line is offered the same
// slot as well. So at most two or three people hold a live offer at once,
// and the first to accept gets it — the others are told it's gone. A slot
// that would otherwise sit idle while one person ignores a notification is
// filled sooner, at the cost of occasionally disappointing a slower
// responder.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { offerSlot } from "../_shared/waitlistOffers.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { trainerId, date, slot } = await req.json();
    if (!trainerId || !date || slot === undefined || slot === null) {
      throw new Error("trainerId, date and slot are required");
    }

    // Any signed-in user may trigger this: it's driven by cancelling a
    // booking, and it can only ever offer a slot to whoever is genuinely
    // next in the queue — there's nothing to gain by calling it.
    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const offeredTo = await offerSlot(trainerId, date, Number(slot));
    return new Response(JSON.stringify({ ok: true, offeredEntryId: offeredTo }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("offer-waitlist-slot failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
