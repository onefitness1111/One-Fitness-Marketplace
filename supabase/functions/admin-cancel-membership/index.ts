// Staff cancelling a CLIENT's membership, with an explicit choice about
// when access actually ends.
//
// cancel-membership is the client cancelling their own, and it always
// schedules the end of the paid-for period — correct there, because the
// client has paid for that time. Staff need both:
//
//   mode: "period_end"  — billing stops now, the client keeps their
//                         sessions until the period they've paid for runs
//                         out. The default, and the fair one.
//   mode: "immediate"   — access ends now. For a refunded cancellation, a
//                         member who has left, or an account being closed.
//
// Kept separate from cancel-membership rather than bolted onto it, because
// that function identifies the client as auth.uid() throughout — the whole
// reason it can't cancel anyone else's. Merging the two would mean
// threading "whose membership is this" through every branch of a function
// whose safety rests on there being no such question.
//
// No cancellation fee is charged here. A fee is something a client agrees
// to when they cancel; staff ending a membership on someone's behalf
// shouldn't silently bill their card. Staff can add a charge explicitly if
// one is owed.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { nextSlotHolder } from "../_shared/planEnrollments.ts";

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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const authed = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) return json({ error: "Not signed in." }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: caller } = await admin.from("profiles").select("role, name").eq("id", user.id).maybeSingle();
    if (!caller || !["owner", "coach"].includes(caller.role)) {
      return json({ error: "Only a coach or the owner can cancel a client's membership." }, 403);
    }

    const { clientId, mode = "period_end", preview = false } = await req.json().catch(() => ({}));
    if (!clientId) return json({ error: "clientId is required" }, 400);
    if (mode !== "period_end" && mode !== "immediate") {
      return json({ error: "mode must be 'period_end' or 'immediate'" }, 400);
    }

    const { data: clientRow } = await admin
      .from("clients")
      .select("profile_id, membership_plan_id, stripe_subscription_id, plans")
      .eq("profile_id", clientId)
      .maybeSingle();
    if (!clientRow) return json({ error: "That client no longer exists." }, 404);
    if (!clientRow.membership_plan_id) {
      return json({ error: "This client has no active membership to cancel." }, 400);
    }

    const subId = clientRow.stripe_subscription_id as string | null;

    // A plan with no subscription behind it — free, a package, or coach
    // assigned — has no paid period to run out, so "let them finish" has
    // nothing to wait for. Say so rather than pretending to schedule it.
    let periodEndsAt: string | null = null;
    if (subId) {
      try {
        const sub = await stripe.subscriptions.retrieve(subId);
        periodEndsAt = new Date(sub.current_period_end * 1000).toISOString().slice(0, 10);
      } catch (e) {
        console.warn("admin-cancel: could not read subscription:", e instanceof Error ? e.message : String(e));
      }
    }
    const canScheduleEnd = !!subId && !!periodEndsAt;
    const effectiveMode = mode === "period_end" && !canScheduleEnd ? "immediate" : mode;

    const { data: planRow } = await admin
      .from("membership_plans").select("data").eq("id", clientRow.membership_plan_id).maybeSingle();
    const planName = (planRow?.data as { name?: string } | null)?.name ?? "membership";

    if (preview) {
      return json({
        planName,
        periodEndsAt,
        canScheduleEnd,
        // What the staff member is about to do, after the fallback above.
        effectiveMode,
      });
    }

    if (effectiveMode === "period_end") {
      try {
        await stripe.subscriptions.update(subId!, { cancel_at_period_end: true });
      } catch (e) {
        console.warn("admin-cancel: Stripe schedule failed, continuing:", e instanceof Error ? e.message : String(e));
      }
      const { error } = await admin.from("clients").update({
        membership_cancels_at: periodEndsAt,
        pending_plan_id: null,
        pending_plan_effective_at: null,
        stripe_schedule_id: null,
      }).eq("profile_id", clientId);
      if (error) throw error;

      console.log(`admin-cancel-membership: ${user.id} scheduled ${clientId}'s ${planName} to end ${periodEndsAt}`);
      return json({ ok: true, mode: "period_end", cancelsAt: periodEndsAt, planName });
    }

    // Immediate: stop billing now, mark the enrollment cancelled, and hand
    // the membership slot to whatever the client still holds. Mirrors what
    // cancel-membership does on its immediate path and what the webhook
    // does when a subscription really ends — leaving `plans` untouched is
    // what previously kept a cancelled plan showing as "Current plan".
    if (subId) {
      try {
        await stripe.subscriptions.cancel(subId);
      } catch (e) {
        console.warn("admin-cancel: Stripe cancel failed, continuing:", e instanceof Error ? e.message : String(e));
      }
    }

    const enrollments = Array.isArray(clientRow.plans) ? clientRow.plans : [];
    const endedPlanId = clientRow.membership_plan_id;
    const nextEnrollments = enrollments.map((e: { planId?: string; status?: string }) =>
      e?.planId === endedPlanId && e?.status === "active" ? { ...e, status: "cancelled" } : e,
    );
    const next = await nextSlotHolder(admin, nextEnrollments);

    const { error } = await admin.from("clients").update({
      membership_plan_id: next?.planId ?? null,
      stripe_subscription_id: next?.subscriptionId ?? null,
      membership_cancels_at: next?.cancelsAt ?? null,
      pending_plan_id: null,
      pending_plan_effective_at: null,
      stripe_schedule_id: null,
      plans: nextEnrollments,
    }).eq("profile_id", clientId);
    if (error) throw error;

    console.log(`admin-cancel-membership: ${user.id} immediately cancelled ${clientId}'s ${planName}`);
    return json({ ok: true, mode: "immediate", cancelsAt: null, planName });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("admin-cancel-membership failed:", message);
    return json({ error: message }, 400);
  }
});
