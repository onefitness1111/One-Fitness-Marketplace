// Cancels a client's own paid membership. If it's a real Stripe
// subscription, cancels the subscription in Stripe FIRST so billing
// actually stops. Deployed WITH jwt verification — a client can only ever
// cancel their own membership; the row is looked up by the caller's own
// auth.uid(), never a client-supplied id.
//
// Also enforces the plan's cancellation policy (Settings on the plan
// itself, not Customize Platform — see PackageSetupModal.jsx): each
// membership plan can require a minimum number of days' notice before
// renewal, and charges an early termination fee (logged, collected
// manually, owner-waivable — see waive-charge) if the client cancels with
// less notice than that. preview:true returns what WOULD happen without
// actually canceling, so the client can see the fee before confirming.
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

/// This client's Stripe Customer, if they have one (they do as soon as
/// they've paid for anything or added a card).
// deno-lint-ignore no-explicit-any
async function stripeCustomerFor(admin: any, profileId: string): Promise<string | null> {
  const { data } = await admin.from("clients").select("stripe_customer_id").eq("profile_id", profileId).maybeSingle();
  return (data?.stripe_customer_id as string | null) ?? null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    // planId: which held plan to act on. Omitted (or the primary slot's own
    // plan) means the primary membership, as before; any other plan the
    // client holds alongside it is handled on its own below.
    const { preview = false, resume = false, planId = null } = await req.json().catch(() => ({}));

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } }
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: clientRow, error: clientErr } = await admin.from("clients")
      .select("stripe_subscription_id, membership_plan_id, plans").eq("profile_id", user.id).maybeSingle();
    if (clientErr) throw clientErr;

    const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

    // ── An additional plan held alongside the primary one ───────────────
    // Each paid one has its own Stripe subscription (enrollment.subscriptionId):
    // cancelling schedules that subscription to end at its paid-through date
    // (enrollment.cancelsAt), and stripe-webhook marks it cancelled when it
    // does. A plan with no subscription (free / coach-assigned) ends now.
    if (planId && planId !== clientRow?.membership_plan_id) {
      const enrollments: any[] = Array.isArray(clientRow?.plans) ? clientRow!.plans : [];
      const entry = enrollments.find((e) => e?.planId === planId && e?.status === "active");
      if (!entry) throw new Error("You don't currently hold that plan.");
      const subId: string | null = entry.subscriptionId ?? null;

      const { data: extraPlanRow } = await admin.from("membership_plans").select("data").eq("id", planId).maybeSingle();
      const extraPlan = extraPlanRow?.data ?? null;
      let endsAt: string | null = null;
      let extraFee = 0;
      if (subId) {
        const sub = await stripe.subscriptions.retrieve(subId);
        const periodEndMs = sub.current_period_end * 1000;
        endsAt = new Date(periodEndMs).toISOString().slice(0, 10);
        const nd = extraPlan?.cancellationNoticeDays || 0, fee = extraPlan?.earlyTerminationFeeCents || 0;
        if (nd > 0 && fee > 0 && Math.ceil((periodEndMs - Date.now()) / 86400000) < nd) extraFee = fee;
      }
      if (preview) {
        return json({ feeCents: extraFee, renewsAt: endsAt, periodEndsAt: endsAt, immediate: !subId });
      }

      let nextEntry: any;
      if (resume) {
        if (!subId) throw new Error("There's no scheduled cancellation to undo.");
        await stripe.subscriptions.update(subId, { cancel_at_period_end: false });
        const { cancelsAt: _drop, ...rest } = entry;
        nextEntry = rest;
      } else if (subId) {
        await stripe.subscriptions.update(subId, { cancel_at_period_end: true });
        nextEntry = { ...entry, cancelsAt: endsAt };
      } else {
        nextEntry = { ...entry, status: "cancelled" };
      }
      const { error: planErr } = await admin.from("clients")
        .update({ plans: enrollments.map((e) => (e === entry ? nextEntry : e)) })
        .eq("profile_id", user.id);
      if (planErr) throw planErr;

      if (!resume && extraFee > 0) {
        const { data: profile } = await admin.from("profiles").select("name").eq("id", user.id).maybeSingle();
        await admin.from("charges").insert({
          client_id: user.id, client_name: profile?.name || "", type: "early_termination_fee",
          date: new Date().toISOString().slice(0, 10),
          at: new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
          amount: extraFee / 100, category: "Early Termination Fee", plan_id: planId, plan_name: extraPlan?.name ?? null,
        });
      }
      return json({ ok: true, resumed: resume, feeCents: resume ? 0 : extraFee, cancelsAt: resume ? null : (subId ? endsAt : null), immediate: !resume && !subId });
    }

    let plan: any = null;
    if (clientRow?.membership_plan_id) {
      const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", clientRow.membership_plan_id).maybeSingle();
      plan = planRow?.data ?? null;
    }
    const noticeDays = plan?.cancellationNoticeDays || 0;
    const feeCentsConfigured = plan?.earlyTerminationFeeCents || 0;

    // A plan with no Stripe subscription behind it — a free plan, a
    // one-time package, or one a coach assigned directly — has no billing
    // period to run out, so there's nothing to schedule: cancelling it can
    // only mean removing it now. Everything else (a real subscription)
    // cancels at the end of the period already paid for, which is what this
    // screen has always promised the client.
    const hasSubscription = !!clientRow?.stripe_subscription_id;

    // "Keep my membership" — undoes a cancellation that's only scheduled
    // (cancel_at_period_end), before the period has actually ended.
    if (resume) {
      if (!hasSubscription) throw new Error("There's no scheduled cancellation to undo.");
      await stripe.subscriptions.update(clientRow!.stripe_subscription_id!, { cancel_at_period_end: false });
      const { error } = await admin.from("clients").update({ membership_cancels_at: null }).eq("profile_id", user.id);
      if (error) throw error;
      return new Response(JSON.stringify({ ok: true, resumed: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    let renewsAt: string | null = null;
    let feeCents = 0;
    // The plan's cancellation fee. With a notice period set it only applies
    // to cancelling inside that window; with no notice period it applies to
    // any cancellation, which is how "cancel the plan, $25 is charged" reads.
    if (feeCentsConfigured > 0) feeCents = feeCentsConfigured;
    if (hasSubscription) {
      const sub = await stripe.subscriptions.retrieve(clientRow!.stripe_subscription_id!);
      const periodEndMs = sub.current_period_end * 1000;
      renewsAt = new Date(periodEndMs).toISOString().slice(0, 10);
      if (noticeDays > 0 && feeCentsConfigured > 0) {
        const daysUntilRenewal = Math.ceil((periodEndMs - Date.now()) / 86400000);
        feeCents = daysUntilRenewal < noticeDays ? feeCentsConfigured : 0;
      }
    }

    if (preview) {
      return new Response(
        // `periodEndsAt` duplicates `renewsAt` under the name the app reads
        // it by; both are returned so neither side has to change in
        // lockstep with the other.
        JSON.stringify({ feeCents, renewsAt, periodEndsAt: renewsAt, noticeDaysRequired: noticeDays, immediate: !hasSubscription }),
        { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
      );
    }

    let cancelsAt: string | null = null;
    if (hasSubscription) {
      try {
        // cancel_at_period_end, NOT an outright cancel: this used to call
        // subscriptions.cancel(), which killed access the instant the
        // client confirmed — directly contradicting the dialog they'd just
        // agreed to ("access continues through <date>") and forfeiting time
        // they had already paid for.
        await stripe.subscriptions.update(clientRow!.stripe_subscription_id!, { cancel_at_period_end: true });
        cancelsAt = renewsAt;
      } catch (e) {
        // Already canceled on Stripe's side (e.g. auto-canceled after
        // repeated failed payments) — fine, still clear it locally below.
        console.warn("cancel-membership: Stripe cancel failed, continuing:", e instanceof Error ? e.message : String(e));
      }
    }

    // Access is kept until the paid-through date when the cancellation is
    // scheduled — only an immediate cancellation clears the plan itself.
    // stripe-webhook's customer.subscription.deleted handler is what
    // finally clears membership_plan_id when the period actually ends.
    // An immediate cancel also marks that plan's enrollment cancelled, the
    // same way the webhook does — `plans` is what says which plans a client
    // holds, so leaving it "active" kept the cancelled plan showing as
    // "Current plan" and still bookable. Packages in the list are untouched.
    const enrollments = Array.isArray(clientRow?.plans) ? clientRow!.plans : [];
    const endedPlanId = clientRow?.membership_plan_id ?? null;
    const nextEnrollments = enrollments.map((e: any) =>
      e?.planId === endedPlanId && e?.status === "active" ? { ...e, status: "cancelled" } : e,
    );
    // The slot is free again after an immediate cancel — the next plan the
    // client still holds (another membership first) takes it over, so their
    // other plans carry on exactly as before.
    const next = cancelsAt ? null : await nextSlotHolder(admin, nextEnrollments);
    const { error: updateErr } = await admin.from("clients")
      .update(
        cancelsAt
          ? { membership_cancels_at: cancelsAt, pending_plan_id: null, pending_plan_effective_at: null, stripe_schedule_id: null }
          : {
              membership_plan_id: next?.planId ?? null,
              stripe_subscription_id: next?.subscriptionId ?? null,
              membership_cancels_at: next?.cancelsAt ?? null,
              pending_plan_id: null, pending_plan_effective_at: null, stripe_schedule_id: null,
              plans: nextEnrollments,
            },
      )
      .eq("profile_id", user.id);
    if (updateErr) throw updateErr;

    // The cancellation fee is taken from the card the client has on file,
    // right now — it's what they agreed to when cancelling. If there's no
    // saved card, or the charge is declined, the fee is still recorded so
    // the gym can collect it, and the cancellation itself still stands.
    let feeCharged = false;
    let feeError: string | null = null;
    if (feeCents > 0) {
      const { data: profile } = await admin.from("profiles").select("name").eq("id", user.id).maybeSingle();
      let paymentIntentId: string | null = null;
      const customerId = await stripeCustomerFor(admin, user.id);
      if (customerId) {
        try {
          const methods = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
          const card = methods.data[0];
          if (!card) throw new Error("no saved card");
          const intent = await stripe.paymentIntents.create({
            amount: feeCents,
            currency: "usd",
            customer: customerId,
            payment_method: card.id,
            off_session: true,
            confirm: true,
            description: `Cancellation fee — ${plan?.name ?? "membership"}`,
            metadata: { profile_id: user.id, kind: "cancellation_fee", plan_id: clientRow?.membership_plan_id ?? "" },
          });
          paymentIntentId = intent.id;
          feeCharged = intent.status === "succeeded";
          if (!feeCharged) feeError = `Payment ${intent.status}`;
        } catch (e) {
          feeError = e instanceof Error ? e.message : String(e);
          console.warn("cancel-membership: fee charge failed:", feeError);
        }
      } else {
        feeError = "no saved card";
      }

      const { error: chargeErr } = await admin.from("charges").insert({
        client_id: user.id,
        client_name: profile?.name || "",
        type: "early_termination_fee",
        date: new Date().toISOString().slice(0, 10),
        at: new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
        amount: feeCents / 100,
        category: "Early Termination Fee",
        description: feeCharged ? "Charged to card on file" : `Not collected (${feeError ?? "unpaid"})`,
        plan_id: clientRow?.membership_plan_id ?? null,
        plan_name: plan?.name ?? null,
        stripe_payment_intent_id: paymentIntentId,
      });
      if (chargeErr) throw chargeErr;
    }

    return new Response(
      JSON.stringify({ ok: true, feeCents, feeCharged, feeError, cancelsAt, immediate: !cancelsAt }),
      { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("cancel-membership failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
