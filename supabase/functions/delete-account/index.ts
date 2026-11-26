// Self-service account deletion — Apple App Review guideline 5.1.1(v):
// an app that lets you create an account must let you delete it from
// inside the app, without emailing or calling support, and deactivation
// alone is not acceptable.
//
// This is the user deleting THEMSELVES. It never takes an id from the
// request body: the account deleted is always the caller's own auth.uid(),
// so this endpoint cannot be turned into "delete anyone". Works for both
// roles — a client and a coach each delete their own account here. Staff
// deleting SOMEONE ELSE stays in delete-client-account/delete-coach-account,
// which are separate, permission-checked, and unchanged.
//
// Order of work, and why:
//   1. Tombstone `profiles.deleted_at` first, so if anything later fails
//      the account is already marked gone and can be swept up.
//   2. Stop the money: cancel any live Stripe subscription immediately and
//      delete the Stripe customer. Done BEFORE the rows disappear, because
//      the customer id lives on the `clients` row.
//   3. Cancel future sessions and tell the other party — a coach turning
//      up to an empty gym is the failure mode this avoids. Past sessions
//      are left alone; they are accounting records.
//   4. Delete uploaded files from Storage.
//   5. Null "who did this" audit columns on OTHER people's rows, and
//      delete this user's own subject-of-record rows that a `profiles`
//      cascade can't reach (NO ACTION FKs), then strip the id out of the
//      jsonb membership arrays (squads, challenges) that have no FK at all.
//   6. Delete the Auth user, which cascades profiles -> clients/trainers ->
//      client_records, bookings, waitlist, blocked_time, reports, blocks.
//
// Steps 5 and 6 mirror delete-client-account/delete-coach-account exactly;
// they are the audited FK map for this schema and must run in this order or
// the cascade is rejected.
//
// What is NOT deleted: rows required for tax and accounting — `charges`,
// `orders` and the `points_ledger` money trail — are anonymised instead,
// with the personal link severed. The Terms of Use say this plainly.
//
// Sign in with Apple is not offered by this app, so there is no Apple
// token to revoke (guideline 5.1.1(v)'s revocation requirement applies only
// to apps that use it).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { deleteAuthUser, authDeleteErrorMessage } from "../_shared/deleteAuthUser.ts";
import { sendPush } from "../_shared/sendPush.ts";
import { sendEmail } from "../_shared/sendEmail.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    // Who is calling — from their JWT, never from the body.
    const authed = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) return json({ error: "Not signed in." }, 401);

    const uid = user.id;
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: me } = await admin
      .from("profiles")
      .select("role, name, email")
      .eq("id", uid)
      .maybeSingle();
    if (!me) return json({ error: "That account no longer exists." }, 404);

    const isCoach = me.role === "coach" || me.role === "owner";

    // The owner is the gym itself. Deleting it would orphan every coach,
    // client, plan and booking in the platform, and there is no way back.
    if (me.role === "owner") {
      return json({
        error:
          "The owner account can't be deleted from the app, because it owns the gym's whole setup. Contact ONE Fitness to transfer ownership first.",
      }, 400);
    }

    // ── 1. Tombstone ────────────────────────────────────────────────────
    await admin.from("profiles").update({ deleted_at: new Date().toISOString() }).eq("id", uid);

    const warnings: string[] = [];

    // ── 2. Stripe: stop billing, then drop the customer ─────────────────
    if (!isCoach) {
      const { data: clientRow } = await admin
        .from("clients")
        .select("stripe_customer_id, stripe_subscription_id, stripe_schedule_id")
        .eq("profile_id", uid)
        .maybeSingle();

      if (clientRow?.stripe_schedule_id) {
        try {
          await stripe.subscriptionSchedules.release(clientRow.stripe_schedule_id);
        } catch (e) {
          warnings.push(`schedule: ${e instanceof Error ? e.message : String(e)}`);
        }
      }
      if (clientRow?.stripe_subscription_id) {
        try {
          // Immediately, not at period end — the account is going away now.
          await stripe.subscriptions.cancel(clientRow.stripe_subscription_id);
        } catch (e) {
          warnings.push(`subscription: ${e instanceof Error ? e.message : String(e)}`);
        }
      }
      if (clientRow?.stripe_customer_id) {
        try {
          // Deleting the customer detaches saved cards with it. Paid
          // invoices survive on the Stripe side for accounting, which is
          // what an accountant and the tax authority both need.
          await stripe.customers.del(clientRow.stripe_customer_id);
        } catch (e) {
          warnings.push(`customer: ${e instanceof Error ? e.message : String(e)}`);
        }
      }
    }

    // ── 3. Cancel future sessions and notify the other party ────────────
    const today = todayIso();
    const bookingCol = isCoach ? "trainer_id" : "client_id";
    // A cancelled booking is one with cancelled_at set — there is no
    // status column; see cancel-session, which uses the same convention.
    const { data: upcoming } = await admin
      .from("bookings")
      .select("id, date, slot_min, client_id, trainer_id, session_type")
      .eq(bookingCol, uid)
      .gte("date", today)
      .is("cancelled_at", null);

    // Who needs telling: the person on the other side of each session.
    const notify = new Set<string>();
    for (const b of upcoming || []) {
      notify.add(isCoach ? b.client_id : b.trainer_id);
    }
    if ((upcoming || []).length > 0) {
      // cancelled_by stays null: the row is about to lose its FK target
      // anyway, and a deleted account isn't a person who can be pointed at.
      await admin
        .from("bookings")
        .update({
          cancelled_at: new Date().toISOString(),
          cancelled_by: null,
          cancellation_scope: "account-deleted",
        })
        .in("id", (upcoming || []).map((b: { id: string }) => b.id));
    }

    for (const otherId of notify) {
      if (!otherId) continue;
      const count = (upcoming || []).filter(
        (b: { client_id: string; trainer_id: string }) =>
          (isCoach ? b.client_id : b.trainer_id) === otherId,
      ).length;
      const who = me.name || (isCoach ? "A coach" : "A client");
      const title = "Session cancelled";
      const body =
        `${who} has closed their ONE Fitness account. ` +
        `${count} upcoming session${count === 1 ? "" : "s"} with them ${count === 1 ? "has" : "have"} been cancelled.`;
      try {
        const { data: tokens } = await admin
          .from("device_tokens")
          .select("token")
          .eq("profile_id", otherId);
        await sendPush((tokens || []).map((t: { token: string }) => t.token), title, body);
      } catch (_) { /* best effort — never block deletion on a push */ }
      try {
        const { data: p } = await admin.from("profiles").select("email").eq("id", otherId).maybeSingle();
        if (p?.email) await sendEmail(p.email, title, body);
      } catch (_) { /* same */ }
    }

    // ── 4. Uploaded files ───────────────────────────────────────────────
    // Buckets are best-effort: a missing bucket must not strand a deletion.
    for (const bucket of ["avatars", "progress-photos", "before-afters", "uploads"]) {
      try {
        const { data: files } = await admin.storage.from(bucket).list(uid);
        if (files && files.length > 0) {
          await admin.storage.from(bucket).remove(files.map((f: { name: string }) => `${uid}/${f.name}`));
        }
      } catch (_) { /* bucket may not exist in this project */ }
    }

    // ── 5a. Anonymise what accounting has to keep ───────────────────────
    // The rows stay for the books; the person they point at does not.
    await admin.from("charges").update({ client_name: "Deleted user" }).eq("client_id", uid);
    await admin.from("orders").update({ client_name: "Deleted user" }).eq("client_id", uid);

    // ── 5b. Null audit columns on other people's rows ───────────────────
    await admin.from("bookings").update({ cancelled_by: null }).eq("cancelled_by", uid);
    await admin.from("platform_settings").update({ updated_by: null }).eq("updated_by", uid);
    await admin.from("platform_settings_audit").update({ changed_by: null }).eq("changed_by", uid);
    await admin.from("blocked_time").update({ created_by: null }).eq("created_by", uid);
    await admin.from("points_ledger").update({ granted_by_user_id: null }).eq("granted_by_user_id", uid);
    await admin.from("merit_badges").update({ granted_by_user_id: null }).eq("granted_by_user_id", uid);
    await admin.from("merit_badges").update({ revoked_by_user_id: null }).eq("revoked_by_user_id", uid);
    await admin.from("reports").update({ reviewed_by: null }).eq("reviewed_by", uid);

    // ── 5c. This user's own rows behind NO ACTION FKs ───────────────────
    await admin.from("points_ledger").delete().eq("client_id", uid);
    await admin.from("merit_badges").delete().eq("client_id", uid);
    await admin.from("coach_pr_events").delete().eq("client_id", uid);
    await admin.from("device_tokens").delete().eq("profile_id", uid);
    if (isCoach) {
      await admin.from("coach_merit_badges").delete().eq("trainer_id", uid);
      await admin.from("clients").update({ primary_trainer_id: null }).eq("primary_trainer_id", uid);
      await admin.from("clients").update({ referred_by_trainer_id: null }).eq("referred_by_trainer_id", uid);
    }

    // ── 5d. jsonb membership arrays with no FK ──────────────────────────
    const { data: squads } = await admin.from("squads").select("id, lead_id, member_ids, member_meta");
    for (const squad of squads || []) {
      if (squad.lead_id === uid) continue; // cascades with the profile
      const memberIds: string[] = squad.member_ids || [];
      if (!memberIds.includes(uid)) continue;
      const memberMeta = { ...(squad.member_meta || {}) };
      delete memberMeta[uid];
      await admin.from("squads").update({
        member_ids: memberIds.filter((id) => id !== uid),
        member_meta: memberMeta,
      }).eq("id", squad.id);
    }
    const { data: challenges } = await admin.from("challenges").select("id, participants");
    for (const challenge of challenges || []) {
      const participants: string[] = challenge.participants || [];
      if (!participants.includes(uid)) continue;
      await admin.from("challenges").update({
        participants: participants.filter((id) => id !== uid),
      }).eq("id", challenge.id);
    }

    // ── 6. The Auth user itself ─────────────────────────────────────────
    // Everything above has already been anonymised, cancelled or removed,
    // so leaving the account itself behind is the worst outcome available —
    // hence the fallback when the Admin API won't do it.
    const delResult = await deleteAuthUser(admin, uid, SUPABASE_URL, SERVICE_ROLE_KEY);
    if (!delResult.ok) {
      console.error(`delete-account: ${authDeleteErrorMessage(delResult)}`);
      return json({
        error: "We couldn't finish deleting your account just now. Please try again in a moment.",
      }, 500);
    }

    console.log(
      `delete-account: ${uid} (${me.role}) deleted themselves; ` +
      `${(upcoming || []).length} upcoming session(s) cancelled; warnings=${JSON.stringify(warnings)}`,
    );
    return json({ ok: true, cancelledSessions: (upcoming || []).length, warnings });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("delete-account failed:", message);
    return json({ error: message }, 400);
  }
});
