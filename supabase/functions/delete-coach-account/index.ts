// Fully deletes a coach — Delete/Archive Behavior spec: a deleted coach "is
// fully removed; must sign up and register again from step one as a new
// profile". The old deleteTrainerRow path only ever removed the `trainers`
// row, leaving `profiles`, the Supabase Auth account, and every reference
// to this coach fully intact — which both breaks re-signup with the same
// email and leaves clients with a dangling `primary_trainer_id`/
// `referred_by_trainer_id` pointing at a coach who no longer exists (silent
// invisibility under a coach-scoped roster — see Delete/Archive audit).
// This function does the full, irreversible job in one authorized call:
//   1. Null out "who did this" audit columns that point at this coach on
//      OTHER people's rows (never delete someone else's data just because
//      this coach once acted on it).
//   2. Delete this coach's own subject-of-record rows that a plain
//      `profiles` cascade can't reach (NO ACTION FKs).
//   3. Clear the dangling primary_trainer_id/referred_by_trainer_id on
//      every client who pointed at this coach — both a NO ACTION FK (would
//      otherwise reject the delete outright) and the actual fix for the
//      "invisible under own-scoped roster" gap.
//   4. Delete the Supabase Auth user itself via the GoTrue Admin REST API
//      (same call shape as admin-reset-mfa) — this CASCADEs profiles ->
//      trainers -> bookings (trainer_id), blocked_time (trainer_id),
//      waitlist (trainer_id), per the schema's own declared ON DELETE
//      CASCADE rules. This is what actually frees the email for a
//      genuinely fresh signup, and what makes this coach's future
//      availability/bookable sessions disappear everywhere at once.
// Order matters: steps 1-3 must run BEFORE step 4, for the same NO ACTION
// FK reason as delete-client-account.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { deleteAuthUser, authDeleteErrorMessage } from "../_shared/deleteAuthUser.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { trainerId } = await req.json();
    if (!trainerId) throw new Error("trainerId is required");

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const authedClient = createClient(
      SUPABASE_URL,
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (callerProfile?.role !== "owner") throw new Error("Only the owner can delete a coach.");

    const { data: targetProfile } = await admin.from("profiles").select("role, name").eq("id", trainerId).maybeSingle();
    if (!targetProfile || targetProfile.role !== "coach") throw new Error("That coach no longer exists.");

    // 1. Null "who did this" audit columns pointing at this coach on rows
    // that belong to someone/something else — never delete those rows.
    await admin.from("bookings").update({ cancelled_by: null }).eq("cancelled_by", trainerId);
    await admin.from("platform_settings").update({ updated_by: null }).eq("updated_by", trainerId);
    await admin.from("platform_settings_audit").update({ changed_by: null }).eq("changed_by", trainerId);
    await admin.from("blocked_time").update({ created_by: null }).eq("created_by", trainerId);
    await admin.from("points_ledger").update({ granted_by_user_id: null }).eq("granted_by_user_id", trainerId);
    await admin.from("merit_badges").update({ granted_by_user_id: null }).eq("granted_by_user_id", trainerId);
    await admin.from("merit_badges").update({ revoked_by_user_id: null }).eq("revoked_by_user_id", trainerId);

    // 2. Delete this coach's own subject-of-record rows (NO ACTION FKs).
    await admin.from("coach_merit_badges").delete().eq("trainer_id", trainerId);
    await admin.from("coach_pr_events").delete().eq("trainer_id", trainerId);

    // 3. Clear the dangling trainer reference on every client who pointed
    // at this coach — required both to satisfy the NO ACTION FK and to fix
    // the "client invisible under own-scoped roster" gap.
    await admin.from("clients").update({ primary_trainer_id: null }).eq("primary_trainer_id", trainerId);
    await admin.from("clients").update({ referred_by_trainer_id: null }).eq("referred_by_trainer_id", trainerId);

    // 4. Delete the Auth account — cascades profiles -> trainers ->
    // bookings(trainer_id), blocked_time(trainer_id), waitlist(trainer_id).
    // This is what frees the email for a real fresh signup and makes every
    // future slot/session this coach offered stop being bookable at once.
    const delResult = await deleteAuthUser(admin, trainerId, SUPABASE_URL, SERVICE_ROLE_KEY);
    if (!delResult.ok) throw new Error(authDeleteErrorMessage(delResult));

    console.log(`delete-coach-account: owner ${user.id} fully deleted coach ${trainerId} (${targetProfile.name})`);
    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("delete-coach-account failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
