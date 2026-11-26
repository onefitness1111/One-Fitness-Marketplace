// The ranked leaderboard for one challenge, for the client-facing screen.
//
// A client can only read their OWN client_records row
// (client_records_select_self_or_staff), which is correct — their
// measurements, habits and logged numbers are nobody else's business. But it
// also means the app cannot work out anyone else's score, and the challenge
// screen was quietly built around that: it showed the signed-in client plus
// `otherLeaderboard`, a field only ever populated by sample data. On a real
// challenge every client saw a leaderboard of exactly one person, themselves.
//
// So the ranking happens here, with the service role, and only the finished
// standings go back — names and scores, never the records they came from.
// Scoring is _shared/challengeScoring.ts, the same module award-points and
// award-merit-badge verify placements with, so the board a client sees and
// the board a prize is paid against cannot disagree.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { rankParticipants } from "../_shared/challengeScoring.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { challengeId } = await req.json();
    if (!challengeId) throw new Error("challengeId is required");

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

    const { data: row } = await admin.from("challenges").select("*").eq("id", challengeId).maybeSingle();
    if (!row) throw new Error("That challenge no longer exists.");

    const participants: string[] = Array.isArray(row.participants) ? row.participants : [];

    // Who may see the standings: the people in it, and staff. Not every
    // signed-in client — otherwise this would be a way to list the gym's
    // members and their progress by guessing challenge ids.
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const isStaff = callerProfile?.role === "owner" || callerProfile?.role === "coach";
    if (!isStaff && !participants.includes(user.id)) {
      // Not an error: a client browsing a challenge they haven't joined gets
      // an empty board and the screen invites them to join.
      return new Response(JSON.stringify({ ok: true, entries: [], participantCount: participants.length }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    if (participants.length === 0) {
      return new Response(JSON.stringify({ ok: true, entries: [], participantCount: 0 }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    const { data: recordRows } = await admin
      .from("client_records").select("profile_id, data").in("profile_id", participants);
    const recordsByClient: Record<string, unknown> = {};
    for (const r of recordRows ?? []) recordsByClient[r.profile_id] = r.data ?? {};

    // Only the attendance scorer reads bookings, and only inside the window —
    // no reason to pull a gym's whole history to rank one challenge.
    const { data: bookingRows } = await admin
      .from("bookings").select("client_id, date, attendance_status")
      .in("client_id", participants)
      .gte("date", row.start_date).lte("date", row.end_date);

    const challengeForScoring = { ...row, startDate: row.start_date, endDate: row.end_date };
    const ranked = rankParticipants(challengeForScoring, recordsByClient, bookingRows ?? []);

    const { data: profileRows } = await admin.from("profiles").select("id, name").in("id", participants);
    const nameById = new Map((profileRows ?? []).map((p: { id: string; name: string | null }) => [p.id, p.name]));

    return new Response(
      JSON.stringify({
        ok: true,
        participantCount: participants.length,
        entries: ranked.map((e: { clientId: string; score: number; rank: number }) => ({
          clientId: e.clientId,
          // A participant whose profile was deleted still holds a place on a
          // finished board; dropping the row would silently renumber everyone
          // below them.
          name: nameById.get(e.clientId) ?? "Former member",
          score: e.score,
          rank: e.rank,
        })),
      }),
      { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("challenge-leaderboard failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
