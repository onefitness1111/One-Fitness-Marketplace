// A client answering "a spot opened up — do you want it?".
//
// Accept creates the real booking and clears them off the waitlist; decline
// (or an expired window) passes the slot straight to the next person, which
// is what keeps the queue moving without anyone having to chase it.
//
// Server-side because accepting writes a booking: a client must not be able
// to book a slot they were never offered, or claim one whose offer has
// already lapsed to someone else.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { offerSlot, closeOtherOffers } from "../_shared/waitlistOffers.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { entryId, accept } = await req.json();
    if (!entryId) throw new Error("entryId is required");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: entry } = await admin.from("waitlist").select("*").eq("id", entryId).maybeSingle();
    if (!entry) throw new Error("That waitlist entry no longer exists.");
    // Only the person the offer was made to can answer it.
    if (entry.client_id !== user.id) throw new Error("That offer isn't yours.");
    if (entry.status !== "offered") throw new Error("That spot is no longer being held for you.");
    if (entry.offer_expires_at && new Date(entry.offer_expires_at).getTime() < Date.now()) {
      // Expired between the notification and the tap. An expired offer
      // doesn't go back in the queue — the window was theirs and it passed.
      await admin.from("waitlist").update({ status: "expired" }).eq("id", entryId);
      await offerSlot(entry.trainer_id, entry.date, Number(entry.slot));
      throw new Error("That offer expired — it's gone to the next person waiting.");
    }

    if (accept !== true) {
      await admin.from("waitlist")
        .update({ status: "declined", declined_at: new Date().toISOString() })
        .eq("id", entryId);
      await offerSlot(entry.trainer_id, entry.date, Number(entry.slot));
      return new Response(JSON.stringify({ ok: true, booked: false }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    // Last check before writing: the slot could have been filled by a coach
    // manually while the offer sat unanswered.
    const { data: taken } = await admin.from("bookings")
      .select("id").eq("trainer_id", entry.trainer_id).eq("date", entry.date)
      .eq("slot_min", entry.slot).is("cancelled_at", null).limit(1);
    if (taken && taken.length > 0) {
      // With cascading offers this is the normal way to lose: someone
      // else who was also offered it accepted first.
      await admin.from("waitlist").update({ status: "missed" }).eq("id", entryId);
      throw new Error("Sorry — someone else claimed that slot first.");
    }

    const { error: bookErr } = await admin.from("bookings").insert({
      client_id: entry.client_id,
      trainer_id: entry.trainer_id,
      date: entry.date,
      slot_min: entry.slot,
      session_type: entry.session_type,
      discipline: entry.discipline,
    });
    if (bookErr) throw bookErr;

    // Off the waitlist entirely — they have the booking now. Anyone else
    // holding a live offer for the same slot is told it's gone.
    await admin.from("waitlist").delete().eq("id", entryId);
    await closeOtherOffers(entry.trainer_id, entry.date, Number(entry.slot), entryId);

    console.log(`respond-waitlist-offer: ${user.id} claimed ${entry.trainer_id} ${entry.date} ${entry.slot}`);
    return new Response(JSON.stringify({ ok: true, booked: true }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("respond-waitlist-offer failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
