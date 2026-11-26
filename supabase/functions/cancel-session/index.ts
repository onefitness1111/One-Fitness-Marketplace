// Schedule tab — owner/coach soft-cancels a whole SESSION (every active
// booking sharing the same trainer/date/slot — a semi-private session can
// have several clients in one row-group), or that session and every future
// occurrence of each affected client's own recurring series. This is a
// SEPARATE cancellation concept from the rest of the app: client
// self-cancel, stopRecurringSeries, and the missed-payment auto-cancel
// sweep all still hard-delete exactly as before. Only a cancellation made
// through this function marks rows cancelled_at/cancelled_by/
// cancellation_scope instead of deleting them, so they stay visible in the
// Schedule tab's day view.
//
// Ownership: bookings' own RLS (schema_phase14) limits INSERT/UPDATE/
// DELETE to "the trainer on the row, or the owner," but this function runs
// as service-role (it may need to touch other clients' rows in the same
// session, and a client's own row isn't owned by the calling coach), so
// that RLS boundary doesn't apply here — the ownership check below is what
// actually enforces "own sessions only" for a coach calling this endpoint.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { trainerId, date, slot, scope } = await req.json();
    if (!trainerId || !date || slot == null) throw new Error("trainerId, date, and slot are required.");
    if (!["instance", "series"].includes(scope)) throw new Error("scope must be 'instance' or 'series'.");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } }
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (!callerProfile || !["owner", "coach"].includes(callerProfile.role)) throw new Error("Only the owner or a coach can cancel a session.");

    const isOwner = callerProfile.role === "owner";
    if (!isOwner && trainerId !== user.id) throw new Error("You can only cancel your own sessions.");

    const today = new Date().toISOString().slice(0, 10);
    if (date < today) throw new Error("Past sessions can't be cancelled.");

    const { data: sessionRows, error: sessionErr } = await admin.from("bookings")
      .select("id, client_id, recurring_series_id")
      .eq("trainer_id", trainerId).eq("date", date).eq("slot_min", slot).is("cancelled_at", null);
    if (sessionErr) throw sessionErr;
    if (!sessionRows || !sessionRows.length) throw new Error("No booked clients found for this session — it may already be cancelled.");

    const cancelledAt = new Date().toISOString();
    const idsToCancel = new Set(sessionRows.map((r) => r.id));

    if (scope === "series") {
      // Each client in this session may belong to their own recurring
      // series (one series = one client's recurring pattern in this app's
      // model, not a shared session-level series) — expand to every
      // future, not-yet-cancelled occurrence of each one.
      const seriesIds = [...new Set(sessionRows.map((r) => r.recurring_series_id).filter(Boolean))];
      if (seriesIds.length) {
        const { data: futureRows, error: futureErr } = await admin.from("bookings")
          .select("id")
          .in("recurring_series_id", seriesIds)
          .gte("date", date)
          .is("cancelled_at", null);
        if (futureErr) throw futureErr;
        (futureRows || []).forEach((r) => idsToCancel.add(r.id));
      }
    }

    const ids = [...idsToCancel];
    const { error: updateErr } = await admin.from("bookings").update({
      cancelled_at: cancelledAt, cancelled_by: user.id, cancellation_scope: scope,
    }).in("id", ids);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ ok: true, cancelledBookingIds: ids, affectedClientIds: [...new Set(sessionRows.map((r) => r.client_id))] }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("cancel-session failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
