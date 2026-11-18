// Automatic reward points: challenge placement, workout streaks, photos,
// and measurements. The caller names the event. This function reads the
// records again and only then writes the ledger.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { computeStreakAwards } from "../_shared/pointsLedger.ts";
import { rankParticipants } from "../_shared/challengeScoring.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 30 * 6;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { clientId, source, sourceRefId } = await req.json();
    if (!clientId || !source) throw new Error("clientId and source are required");
    if (!sourceRefId) throw new Error("sourceRefId is required for every automatic award source.");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const isSelf = user.id === clientId;
    const isStaff = caller && ["owner", "coach"].includes(caller.role);
    if (!isSelf && !isStaff) throw new Error("Not authorized for this client.");

    if (source === "workout_streak" && sourceRefId === "scan") {
      const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
      const awards = computeStreakAwards(recordRow?.data?.workoutLogs || []);
      let amount = 0;
      for (const a of awards) {
        const { data: existing } = await admin.from("points_ledger")
          .select("id").eq("client_id", clientId).eq("source", source).eq("source_ref_id", a.weekEnding).maybeSingle();
        if (existing) continue;
        const nowIso = new Date().toISOString();
        const { error } = await admin.from("points_ledger").insert({
          client_id: clientId, amount: 3, type: "earn", source, source_ref_id: a.weekEnding,
          earned_at: nowIso, expires_at: new Date(Date.now() + SIX_MONTHS_MS).toISOString(), created_at: nowIso,
        });
        if (error && error.code !== "23505") throw error;
        if (!error) amount += 3;
      }
      return new Response(JSON.stringify({ ok: true, amount }), { headers: { ...CORS, "Content-Type": "application/json" } });
    }

    const { data: existing } = await admin.from("points_ledger")
      .select("id").eq("client_id", clientId).eq("source", source).eq("source_ref_id", sourceRefId).maybeSingle();
    if (existing) {
      return new Response(JSON.stringify({ ok: true, alreadyAwarded: true }), { headers: { ...CORS, "Content-Type": "application/json" } });
    }

    let amount = 0;
    if (source === "challenge_participation" || source === "challenge_1st" || source === "challenge_2nd") {
      const { data: challenge } = await admin.from("challenges").select("*").eq("id", sourceRefId).maybeSingle();
      if (!challenge) throw new Error("Challenge not found.");
      const today = new Date().toISOString().slice(0, 10);
      if (!(challenge.end_date < today)) throw new Error("This challenge hasn't ended yet.");
      const participants: string[] = challenge.participants || [];
      if (!participants.includes(clientId)) throw new Error("This client didn't participate in that challenge.");
      if (source === "challenge_participation") {
        amount = 1;
      } else {
        const { data: recordRows } = await admin.from("client_records").select("profile_id, data").in("profile_id", participants);
        const recordsByClient: Record<string, any> = {};
        (recordRows || []).forEach((r: any) => { recordsByClient[r.profile_id] = r.data; });
        const { data: bookingRows } = await admin.from("bookings").select("client_id, attendance_status, date").in("client_id", participants);
        const ranked = rankParticipants({ ...challenge, startDate: challenge.start_date, endDate: challenge.end_date }, recordsByClient, bookingRows || []);
        const mine = ranked.find((r) => r.clientId === clientId);
        if (!mine) throw new Error("Couldn't compute placement.");
        if (source === "challenge_1st" && mine.rank !== 1) throw new Error("Not ranked 1st.");
        if (source === "challenge_2nd" && mine.rank !== 2) throw new Error("Not ranked 2nd.");
        amount = source === "challenge_1st" ? 5 : 3;
      }
    } else if (source === "workout_streak") {
      const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
      const awards = computeStreakAwards(recordRow?.data?.workoutLogs || []);
      if (!awards.some((a) => a.weekEnding === sourceRefId)) throw new Error("That streak block isn't complete.");
      amount = 3;
    } else if (source === "progress_photo" || source === "measurement") {
      const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
      const list = source === "progress_photo" ? (recordRow?.data?.photos || []) : (recordRow?.data?.measurements || []);
      const hasEntry = list.some((entry: any) => String(entry.date || "").slice(0, 7) === sourceRefId);
      if (!hasEntry) throw new Error("No entry logged for that month.");
      amount = 1;
    } else {
      throw new Error(`Unknown automatic source: ${source}`);
    }

    const nowIso = new Date().toISOString();
    const { error: insertErr } = await admin.from("points_ledger").insert({
      client_id: clientId, amount, type: "earn", source, source_ref_id: sourceRefId,
      earned_at: nowIso, expires_at: new Date(Date.now() + SIX_MONTHS_MS).toISOString(), created_at: nowIso,
    });
    if (insertErr) throw insertErr;
    return new Response(JSON.stringify({ ok: true, amount }), { headers: { ...CORS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("award-points failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS, "Content-Type": "application/json" } });
  }
});
