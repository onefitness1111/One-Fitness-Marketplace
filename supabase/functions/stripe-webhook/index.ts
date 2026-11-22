// Receives Stripe webhook events and is the ONLY place that actually
// grants a paid plan or clears one after cancellation/non-payment — the
// app itself never grants a paid membership_plan_id directly from the
// client (blocked by trg_prevent_membership_self_grant, see
// schema_phase5_stripe.sql). Deployed with --no-verify-jwt since Stripe
// calls this anonymously; the Stripe signature check below is what
// verifies a request is genuinely from Stripe instead of Supabase's normal
// JWT check. See supabase/STRIPE_SETUP.md for deploy + webhook setup steps.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { fulfillSingleSessionPayment } from "../_shared/singleSession.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger } from "../_shared/pointsLedger.ts";
import { syncMeritBadgePoints } from "../_shared/meritBadgePoints.ts";
import { sendEmail } from "../_shared/sendEmail.ts";
import { swapMembershipEnrollment, clientBySubscription, nextSlotHolder } from "../_shared/planEnrollments.ts";
import { sendSms } from "../_shared/sendSms.ts";
import { sendPush } from "../_shared/sendPush.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
// Deno's edge runtime doesn't support Node's synchronous crypto, so the
// signature check needs Stripe's async/SubtleCrypto-based verifier instead
// of the default constructEvent.
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 30 * 6;
const THIRTY_DAYS_MS = 1000 * 60 * 60 * 24 * 30;

// Shared by every server-side trigger below — looks up every registered
// device for [profileId] and sends to all of them. Best-effort: sendPush
// itself already swallows its own errors, so this never throws.
async function pushToProfile(profileId: string, title: string, body: string) {
  const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
  await sendPush((rows || []).map((r) => r.token as string), title, body);
}

// Best-effort notification only — referral credit happens here, unattended,
// server-side, with no logged-in frontend session to piggyback an email
// send off of (unlike a grant, which the coach/owner's own browser sends
// right after calling grant-points). Same SMTP secrets send-email/index.ts
// already reads; a failure here is logged and swallowed, never allowed to
// undo or block the points credit itself.
async function sendReferralEmail(toEmail: string, name: string) {
  await sendEmail(
    toEmail,
    "You just earned 3 rewards points!",
    `Hi ${name},\n\nSomeone you referred just completed their first purchase — you've been credited 3 rewards points. Check the Rewards tab in the app to see your balance.\n\n— ONE Fitness`,
  );
}

// Voids whatever's left of a referral credit if the referred client's
// purchase that triggered it gets refunded or their membership cancelled
// within 30 days — called from both the subscription-cancellation branch
// below and refund-charge/index.ts (a refunded one-time purchase).
async function clawbackReferral(referredClientId: string, reasonSuffix: string) {
  const { data: referralRow } = await admin.from("points_ledger")
    .select("*").eq("source", "referral").eq("source_ref_id", referredClientId).eq("type", "earn").maybeSingle();
  if (!referralRow) return;
  if (Date.now() - new Date(referralRow.created_at).getTime() > THIRTY_DAYS_MS) return;

  const { data: existingVoid } = await admin.from("points_ledger").select("id").eq("voided_by_ledger_id", referralRow.id).maybeSingle();
  if (existingVoid) return;

  const { data: allRows } = await admin.from("points_ledger").select("*").eq("client_id", referralRow.client_id);
  const { lots } = replayLedger(allRows || []);
  const lot = lots.find((l) => l.id === referralRow.id);
  const remaining = lot?.remaining || 0;
  if (remaining <= 0) return;

  const { error } = await admin.from("points_ledger").insert({
    client_id: referralRow.client_id, amount: -remaining, type: "void", source: "referral_clawback",
    voided_by_ledger_id: referralRow.id, reason: `Referred client's purchase was ${reasonSuffix} within 30 days.`,
    created_at: new Date().toISOString(),
  });
  if (error) throw error;
  console.log(`stripe-webhook: referral clawback — voided ${remaining} pts from ${referralRow.client_id}`);
}

/// Roll-over (Plans → Advanced → "roll over unused sessions"): when a
/// membership renews, sessions the client didn't use last month carry into
/// the new month, up to the plan's roll-over limit. Written onto that plan's
/// enrollment and stamped with the month it belongs to, so it's spent at the
/// end of that month rather than stacking up.
// deno-lint-ignore no-explicit-any
async function applyRollover(admin: any, clientRow: any, subscriptionId: string): Promise<void> {
  try {
    const enrollments: any[] = Array.isArray(clientRow.plans) ? clientRow.plans : [];
    // The plan this subscription renews: the primary slot's, or the
    // additional membership carrying this subscription id.
    const entry = enrollments.find((e) => e?.subscriptionId === subscriptionId && e?.status === "active")
      ?? enrollments.find((e) => e?.planId === clientRow.membership_plan_id && e?.status === "active");
    if (!entry?.planId) return;

    const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", entry.planId).maybeSingle();
    const plan = planRow?.data;
    if (!plan || plan.kind !== "membership") return;
    if (plan.rollover?.enabled !== true) return;
    const maxVisits = Number(plan.rollover?.maxVisits) || 0;
    const allowance = Number(plan.maxSessions) || 0;
    if (maxVisits <= 0 || allowance <= 0) return;

    // Last month's usage on this plan. Sessions the gym gave back (early
    // cancel, coach-cancelled) never counted as used, same as in the app.
    const now = new Date();
    const prev = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
    const prevMonth = prev.toISOString().slice(0, 7);
    const { data: used } = await admin.from("bookings")
      .select("id, session_type, plan_id, attendance_status, is_physical_assessment, date")
      .eq("client_id", clientRow.profile_id)
      .gte("date", `${prevMonth}-01`)
      .lte("date", `${prevMonth}-31`);
    const givenBack = ["early-cancel", "coach-cancelled"];
    const usedCount = (used ?? []).filter((b: any) =>
      !b.is_physical_assessment &&
      !givenBack.includes(b.attendance_status) &&
      (b.plan_id ? b.plan_id === entry.planId : (plan.allowedTypes ?? []).includes(b.session_type))
    ).length;

    const remaining = Math.max(0, allowance - usedCount);
    const carried = Math.min(remaining, maxVisits);
    const thisMonth = now.toISOString().slice(0, 7);
    const next = enrollments.map((e) =>
      e === entry ? { ...e, rolloverSessions: carried, rolloverMonth: thisMonth } : e,
    );
    const { error } = await admin.from("clients").update({ plans: next }).eq("profile_id", clientRow.profile_id);
    if (error) throw error;
    console.log(`stripe-webhook: rolled over ${carried} session(s) on ${entry.planId} for ${clientRow.profile_id}`);
  } catch (e) {
    // A roll-over that fails must never fail the renewal itself.
    console.error("stripe-webhook: rollover failed:", e instanceof Error ? e.message : String(e));
  }
}

serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  const body = await req.text();

  let event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body, signature ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "", undefined, cryptoProvider
    );
  } catch (e) {
    console.error("stripe-webhook: signature verification failed:", e instanceof Error ? e.message : String(e));
    return new Response("Invalid signature", { status: 400 });
  }

  // Idempotency — Stripe retries a webhook delivery on any non-2xx
  // response or timeout, so the same event can arrive more than once.
  // Record the event id before doing any work; if it's already there, this
  // delivery is a retry of one already fully processed, so no-op it.
  const { error: dupeErr } = await admin.from("stripe_processed_events").insert({ id: event.id });
  if (dupeErr) {
    console.log(`stripe-webhook: ${event.id} already processed, skipping.`);
    return new Response(JSON.stringify({ ok: true, duplicate: true }), { headers: { "Content-Type": "application/json" } });
  }

  try {
    if (event.type === "checkout.session.completed" || event.type === "payment_intent.succeeded") {
      // Two shapes end in the same grant: the legacy hosted-Checkout session,
      // and the PaymentIntent the in-app Payment Sheet confirms. Normalizing
      // here keeps one grant path rather than two that can drift apart.
      let meta: Record<string, string> = {};
      let customerId: string | null = null;
      let subscriptionId: string | null = null;
      let paymentIntentId: string | null = null;
      let amountTotal = 0;
      let sourceRefId = "";
      let sessionMode: string | null = null;

      if (event.type === "checkout.session.completed") {
        const session = event.data.object as Stripe.Checkout.Session;
        meta = (session.metadata ?? {}) as Record<string, string>;
        customerId = typeof session.customer === "string" ? session.customer : session.customer?.id ?? null;
        subscriptionId = typeof session.subscription === "string" ? session.subscription : null;
        paymentIntentId = typeof session.payment_intent === "string" ? session.payment_intent : null;
        amountTotal = session.amount_total ?? 0;
        sourceRefId = session.id;
        sessionMode = session.mode ?? null;
      } else {
        const pi = event.data.object as Stripe.PaymentIntent;
        meta = (pi.metadata ?? {}) as Record<string, string>;
        customerId = typeof pi.customer === "string" ? pi.customer : pi.customer?.id ?? null;
        paymentIntentId = pi.id;
        amountTotal = pi.amount;
        sourceRefId = pi.id;
        // Only the intent that create-payment-intent built carries plan_id.
        // Renewal invoices produce their own intents without it, so those
        // fall through to the invoice.paid handler instead of re-granting.
        const invoiceId = typeof (pi as unknown as { invoice?: string }).invoice === "string"
          ? (pi as unknown as { invoice: string }).invoice
          : null;
        if (invoiceId) {
          try {
            const inv = await stripe.invoices.retrieve(invoiceId);
            subscriptionId = typeof inv.subscription === "string" ? inv.subscription : null;
          } catch (invErr) {
            console.error("stripe-webhook: couldn't read invoice for intent:", invErr instanceof Error ? invErr.message : String(invErr));
          }
        }
        sessionMode = subscriptionId ? "subscription" : "payment";
      }

      // A client paying off what they owe (late-cancel / no-show fees that
      // couldn't be collected): credit the balance by what was paid, record it,
      // and stop. The booking block lifts once the balance is no longer negative.
      if (meta.kind === "balance_payment" && meta.profile_id) {
        const { data: newBalance } = await admin.rpc("adjust_client_balance", {
          p_client: meta.profile_id,
          p_delta: amountTotal,
        });
        const { data: payer } = await admin.from("profiles").select("name").eq("id", meta.profile_id).maybeSingle();
        await admin.from("charges").insert({
          client_id: meta.profile_id,
          client_name: payer?.name ?? "",
          type: "purchase",
          date: new Date().toISOString().slice(0, 10),
          at: new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
          amount: amountTotal / 100,
          category: "Balance payment",
          description: "Paid outstanding balance",
          stripe_payment_intent_id: paymentIntentId,
        });
        console.log(`stripe-webhook: balance payment ${amountTotal}c from ${meta.profile_id}, balance now ${newBalance}`);
        return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
      }

      // A single-session purchase: credit it and book the seat (atomically,
      // refunding if the session filled). The app's confirm call may have
      // already done this - fulfilment is idempotent, so either order is fine.
      // "single_session_staff" was settled synchronously by the staff function.
      if (meta.kind === "single_session_staff") {
        return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
      }
      if (meta.kind === "single_session" && paymentIntentId) {
        const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
        const res = await fulfillSingleSessionPayment({ admin, stripe, pi });
        console.log(`stripe-webhook: single session ${paymentIntentId} -> ${res.status}`);
        return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
      }

      // Merchandise, not a plan: decrement the size that was bought and
      // record the sale, then stop — there's no access to grant. Stock moves
      // here rather than at checkout time so an abandoned payment can't eat
      // inventory nobody paid for.
      if (meta.product_id) {
        const productId = meta.product_id;
        const boughtSize = meta.size ?? "";
        const qty = parseInt(meta.quantity || "1", 10) || 1;
        const { data: prodRow } = await admin.from("products").select("data").eq("id", productId).maybeSingle();
        const product = prodRow?.data;
        if (product) {
          const sizes: Array<{ label: string; inventory: number }> = Array.isArray(product.sizes) ? product.sizes : [];
          const nextSizes = sizes.map((s) =>
            s.label === boughtSize
              // Clamped at zero: two people checking out the last item
              // simultaneously would otherwise drive stock negative.
              ? { ...s, inventory: Math.max(0, (s.inventory || 0) - qty) }
              : s
          );
          await admin.from("products").update({ data: { ...product, sizes: nextSizes } }).eq("id", productId);
        }

        const { data: buyer } = await admin.from("profiles").select("name").eq("id", meta.profile_id).maybeSingle();
        const now = new Date();
        await admin.from("charges").insert({
          client_id: meta.profile_id,
          client_name: buyer?.name || "",
          type: "purchase",
          date: now.toISOString().slice(0, 10),
          at: now.toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
          amount: amountTotal / 100,
          category: product?.category || "Products",
          description: `${meta.product_name || "Product"}${boughtSize ? ` (${boughtSize})` : ""} x${qty}`,
          stripe_payment_intent_id: paymentIntentId,
        });
        // The event was already recorded in stripe_processed_events before
        // this handler ran (and is removed again if we throw), so returning
        // here is all that's needed to stop it falling through to the
        // plan-granting path below.
        // The order is what staff fulfil and the buyer tracks; the charge
        // row above is the money ledger. Both are written because they
        // answer different questions and have different lifecycles — an
        // order gets prepared and collected long after the payment settled.
        const { error: orderErr } = await admin.from("orders").insert({
          client_id: meta.profile_id,
          client_name: buyer?.name || "",
          product_id: productId,
          product_name: meta.product_name || "",
          size: boughtSize || null,
          quantity: qty,
          amount_cents: amountTotal,
          status: "paid",
          stripe_payment_intent_id: paymentIntentId,
        });
        if (orderErr) throw orderErr;

        console.log(`stripe-webhook: product ${productId} (${boughtSize}) x${qty} sold to ${meta.profile_id}`);
        return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
      }

      const profileId = meta.profile_id;
      const planId = meta.plan_id;
      if (profileId && planId) {
        const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", planId).maybeSingle();
        const plan = planRow?.data;
        const { data: profile } = await admin.from("profiles").select("name, email").eq("id", profileId).maybeSingle();

        // Billing Cycle Anchor Date spec §4 — "copied at creation time":
        // read the day back off the REAL resulting Stripe subscription
        // (not re-derived from create-checkout-session's own request)
        // so this is always accurate, whether an explicit anchor was
        // requested or Stripe just defaulted to today's day.
        let billingAnchorDay: number | null = null;
        if (subscriptionId) {
          try {
            const sub = await stripe.subscriptions.retrieve(subscriptionId);
            billingAnchorDay = new Date(sub.billing_cycle_anchor * 1000).getUTCDate();
          } catch (subErr) {
            console.error("stripe-webhook: couldn't read back billing_cycle_anchor:", subErr instanceof Error ? subErr.message : String(subErr));
          }
        }

        // A program (personalized or nutrition) is bought *alongside*
        // whatever access the client already has — it grants programming,
        // not gym access or a session balance. Writing it into
        // membership_plan_id would silently replace their membership, and
        // take their sessions and billing with it.
        const isProgram = plan?.kind === "program" || plan?.kind === "nutritionProgram";

        // Every purchase is appended to `plans`, which is what lets a client
        // hold several at once: one recurring membership plus any number of
        // packages and programs. membership_plan_id is only the
        // *subscription slot* — the plan cancel/change/freeze operate on.
        const { data: existing } = await admin.from("clients")
          .select("plans, membership_plan_id, stripe_subscription_id").eq("profile_id", profileId).maybeSingle();
        const enrollments = Array.isArray(existing?.plans) ? existing!.plans : [];
        const today = new Date().toISOString().slice(0, 10);
        const isMembership = plan?.kind === "membership";
        const nextEnrollments = [
          // Re-buying something already held refreshes that entry instead of
          // stacking a duplicate one next to it.
          ...enrollments.filter((e: any) => e?.planId !== planId),
          {
            planId, status: "active", startDate: today, termMonths: plan?.termMonths ?? null,
            // Each paid membership keeps its own subscription id, so a client
            // can hold several and each renews / is cancelled on its own.
            ...(subscriptionId ? { subscriptionId } : {}),
            // An expiry a coach or owner set when selling this. After this
            // date the plan stops counting as held, so its sessions can no
            // longer be booked against — which is what lets staff sell "six
            // months of access" rather than access forever.
            ...(meta.access_expires_at ? { endsAt: meta.access_expires_at } : {}),
          },
        ];

        // Who takes the primary slot. A client can hold several plans at
        // once, so a new plan never pushes out a PAID membership that's
        // already there — it sits alongside in `plans` with its own balance
        // and its own subscription. It takes the slot only when the slot is
        // empty, or (for a membership) when the slot holds something with no
        // subscription behind it — a free, coach-assigned or package plan.
        const slotHasPaidMembership = !!existing?.membership_plan_id && !!existing?.stripe_subscription_id;
        const takesSlot = !isProgram && (
          !existing?.membership_plan_id || (isMembership && !slotHasPaidMembership)
        );

        const { error: grantErr } = await admin.from("clients").update({
          ...(takesSlot ? { membership_plan_id: planId } : {}),
          plans: nextEnrollments,
          stripe_customer_id: customerId,
          // Only the slot's own plan owns the primary subscription id — an
          // additional membership keeps its id on its enrollment instead,
          // and a one-time package has none and must not blank anything.
          ...(takesSlot && isMembership && subscriptionId ? { stripe_subscription_id: subscriptionId } : {}),
          // Buying into the slot supersedes any pending cancellation — without
          // this, a client who cancels and then changes their mind and buys
          // again would still see "ends on <old date>" over the new plan.
          ...(takesSlot && isMembership ? { membership_cancels_at: null } : {}),
          ...(billingAnchorDay && takesSlot && isMembership ? { billing_anchor_day: billingAnchorDay } : {}),
        }).eq("profile_id", profileId);
        if (grantErr) throw grantErr;

        // The ONE Fitness badge itself is awarded by the trigger on
        // clients.membership_plan_id (migration 18), in the same
        // transaction as the update above — so it already exists by now.
        // What the trigger can't do is the points side: the 5-active-badges
        // bonus runs through the FIFO ledger calculator, which only exists
        // here. Without this, a purchase that takes a client to their fifth
        // badge would award the badge but leave the bonus uncredited until
        // something else touched their badges.
        await syncMeritBadgePoints(admin, profileId);

        // subtotal/fee come from the session's own metadata — captured at
        // checkout-creation time by create-checkout-session, not
        // recomputed here, so a settings change between session creation
        // and webhook delivery can never retroactively change what a
        // client was actually charged. Only present for mode:"payment";
        // session.payment_intent is null for subscriptions (the charge
        // lives on the subscription's invoice instead) — refunds are
        // scoped to one-time purchases only for now, so that's left null
        // there rather than fetched.
        const subtotalCents = parseInt(meta.subtotal_cents || "0", 10) || amountTotal;
        const feeCents = parseInt(meta.fee_cents || "0", 10) || 0;
        const date = new Date().toISOString().slice(0, 10);
        const at = new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

        const chargeRows = [{
          client_id: profileId,
          client_name: profile?.name || "",
          type: "purchase",
          date, at,
          amount: subtotalCents / 100,
          category: plan?.category || null,
          plan_id: planId,
          plan_name: plan?.name || null,
          stripe_payment_intent_id: paymentIntentId,
        }];
        if (feeCents > 0) {
          chargeRows.push({
            client_id: profileId,
            client_name: profile?.name || "",
            type: "processing_fee",
            date, at,
            amount: feeCents / 100,
            category: "Processing Fee",
            plan_id: planId,
            plan_name: plan?.name || null,
            stripe_payment_intent_id: paymentIntentId,
          });
        }
        // Coach Code referral commission — surcharge_cents/referring_trainer_id
        // come from session metadata (captured, not recomputed, at checkout
        // creation time by create-checkout-session — same "trust the
        // metadata over live state" reasoning as subtotal/fee above). One
        // charge row per completed checkout, credited to the referring
        // coach; Payroll sums these by trainer_id/category for that coach's
        // referral income (see report_utils.dart referralCommissionInRange).
        const referringTrainerId = meta.referring_trainer_id;
        const surchargeCents = parseInt(meta.surcharge_cents || "0", 10) || 0;
        if (referringTrainerId && surchargeCents > 0) {
          const { data: referringTrainerProfile } = await admin.from("profiles").select("name").eq("id", referringTrainerId).maybeSingle();
          chargeRows.push({
            client_id: profileId,
            client_name: profile?.name || "",
            type: "manual",
            date, at,
            amount: surchargeCents / 100,
            category: "referral_commission",
            description: "Coach Code Commission",
            plan_id: planId,
            plan_name: plan?.name || null,
            trainer_id: referringTrainerId,
            trainer_name: referringTrainerProfile?.name || null,
            stripe_payment_intent_id: paymentIntentId,
          });
        }
        const { error: chargeErr } = await admin.from("charges").insert(chargeRows);
        if (chargeErr) throw chargeErr;

        console.log(`stripe-webhook: granted plan ${planId} to ${profileId}`);

        // Notifications spec — "Successful payment (receipt)" / "Package
        // purchased": both fire off this one event (mode:"subscription" for
        // a recurring membership, mode:"payment" for a one-time package) —
        // best-effort, never allowed to affect the actual grant above.
        if (profile?.email) {
          const isSubscription = sessionMode === "subscription";
          try {
            await sendEmail(
              profile.email,
              isSubscription ? "Payment received" : "Package purchased",
              `Hi ${profile.name || "there"},\n\n` +
                `Your payment of $${(subtotalCents / 100).toFixed(2)} for ${plan?.name || "your plan"} was successful.` +
                `${isSubscription ? " Your membership is now active." : " Your package has been added to your account."}` +
                `\n\n— ONE Fitness`,
            );
          } catch (emailErr) {
            console.error("stripe-webhook: payment receipt email failed:", emailErr instanceof Error ? emailErr.message : String(emailErr));
          }
          try {
            await pushToProfile(profileId, isSubscription ? "Payment received" : "Package purchased", `$${(subtotalCents / 100).toFixed(2)} for ${plan?.name || "your plan"}.`);
          } catch (pushErr) {
            console.error("stripe-webhook: payment receipt push failed:", pushErr instanceof Error ? pushErr.message : String(pushErr));
          }
        }

        // Points redemption — only written now that payment is actually
        // confirmed, matching this app's "nothing real for an abandoned
        // checkout" doctrine. The discount itself was already applied at
        // checkout time via a one-time Stripe coupon (create-checkout-session);
        // this just records the ledger row and clears the flag.
        const redeemedPoints = parseInt(meta.redeemed_points || "0", 10) || 0;
        if (redeemedPoints > 0) {
          const { error: redeemErr } = await admin.from("points_ledger").insert({
            client_id: profileId, amount: -redeemedPoints, type: "redeem", source: "redemption_checkout",
            source_ref_id: sourceRefId, created_at: new Date().toISOString(),
          });
          if (redeemErr) throw redeemErr;
          await admin.from("clients").update({ redeem_points_next_renewal: false }).eq("profile_id", profileId);
          console.log(`stripe-webhook: redeemed ${redeemedPoints} pts for ${profileId} on ${sourceRefId}`);
        }

        // Referral credit — only present in metadata on a client's
        // genuinely first-ever purchase (MembershipsHub only shows the
        // field then); still re-validated here rather than trusted.
        const referralEmail = meta.referral_email;
        if (referralEmail) {
          const { data: referrer } = await admin.from("profiles").select("id, name, email").eq("role", "client").ilike("email", referralEmail).maybeSingle();
          const { data: referrerClientRow } = referrer
            ? await admin.from("clients").select("membership_plan_id").eq("profile_id", referrer.id).maybeSingle()
            : { data: null };
          if (referrer && referrer.id !== profileId && referrerClientRow?.membership_plan_id) {
            const nowIso = new Date().toISOString();
            const { error: referralErr } = await admin.from("points_ledger").insert({
              client_id: referrer.id, amount: 3, type: "earn", source: "referral", source_ref_id: profileId,
              earned_at: nowIso, expires_at: new Date(Date.now() + SIX_MONTHS_MS).toISOString(), created_at: nowIso,
            });
            if (referralErr) throw referralErr;
            console.log(`stripe-webhook: referral credit — ${referrer.id} earned 3 points for referring ${profileId}`);
            if (referrer.email) {
              try {
                await sendReferralEmail(referrer.email, referrer.name || "there");
              } catch (emailErr) {
                console.error("stripe-webhook: referral email failed (points still credited):", emailErr instanceof Error ? emailErr.message : String(emailErr));
              }
            }

            // Merit Badge — Community Builder. This is the one trusted
            // place a referral is ever confirmed, so it's granted directly
            // here rather than via a client-triggered award-merit-badge
            // scan (there's nothing for a generic caller to re-verify).
            // Active for 6 months, reset by every new referral — award-
            // merit-badge's opportunistic recheck is what actually expires
            // a stale one (no cron), so a fresh referral just needs to
            // reset earned_at on the existing active row rather than
            // insert a second one (which the partial unique index would
            // reject anyway while one's still active).
            const { data: existingBadge } = await admin.from("merit_badges")
              .select("id").eq("client_id", referrer.id).eq("badge_key", "community_builder").is("revoked_at", null).maybeSingle();
            const badgeErr = existingBadge
              ? (await admin.from("merit_badges").update({ earned_at: nowIso, source_ref_id: profileId }).eq("id", existingBadge.id)).error
              : (await admin.from("merit_badges").insert({
                  client_id: referrer.id, badge_key: "community_builder", earned_method: "automatic", source_ref_id: profileId, earned_at: nowIso,
                })).error;
            if (badgeErr && badgeErr.code !== "23505") {
              console.error("stripe-webhook: community_builder badge upsert failed:", badgeErr.message);
            }
            await syncMeritBadgePoints(admin, referrer.id);
          } else {
            console.log(`stripe-webhook: referral email ${referralEmail} matched no active, distinct client — no credit given.`);
          }
        }
      }
    } else if (event.type === "customer.subscription.deleted") {
      const subscription = event.data.object as Stripe.Subscription;
      const endingClient = await clientBySubscription(admin, subscription.id, "profile_id, membership_plan_id, stripe_subscription_id, plans");
      if (endingClient?.profile_id) {
        // The ended membership's enrollment is marked cancelled rather than
        // removed: `plans` is also what says which plans a client holds, so
        // leaving it "active" would keep the dead membership bookable. Every
        // other plan in the list is untouched.
        const isSlot = endingClient.stripe_subscription_id === subscription.id;
        const enrollments: any[] = Array.isArray(endingClient.plans) ? endingClient.plans : [];
        const endedPlanId = isSlot
          ? endingClient.membership_plan_id
          : enrollments.find((e) => e?.subscriptionId === subscription.id)?.planId ?? null;
        const nextEnrollments = enrollments.map((e) =>
          e?.status === "active" && (e?.subscriptionId === subscription.id || e?.planId === endedPlanId)
            ? { ...e, status: "cancelled" }
            : e,
        );
        let update: Record<string, unknown> = { plans: nextEnrollments };
        if (isSlot) {
          // The primary slot is free again — hand it to the next plan the
          // client still holds (another membership first), so their other
          // plans keep working as before. membership_cancels_at follows
          // that plan: it's the "ends on <date>" countdown, and the one for
          // the plan that just ended is spent.
          const next = await nextSlotHolder(admin, nextEnrollments);
          update = {
            ...update,
            membership_plan_id: next?.planId ?? null,
            stripe_subscription_id: next?.subscriptionId ?? null,
            membership_cancels_at: next?.cancelsAt ?? null,
          };
        }
        const { error } = await admin.from("clients").update(update).eq("profile_id", endingClient.profile_id);
        if (error) throw error;
        console.log(`stripe-webhook: subscription ${subscription.id} ended, plan ${endedPlanId} cancelled`);
        // If that was their last plan, the trigger has just revoked the ONE
        // Fitness badge; re-run the points calculation so a bonus they no
        // longer qualify for is withdrawn rather than left standing. A
        // no-op when they still hold another plan.
        await syncMeritBadgePoints(admin, endingClient.profile_id);
        await clawbackReferral(endingClient.profile_id, "cancelled");
      }
    } else if (event.type === "customer.subscription.updated") {
      const subscription = event.data.object as Stripe.Subscription;

      // Case 1 — a scheduled end-of-cycle plan change (change-membership-plan,
      // timing:"end_of_cycle") just transitioned: the subscription's price
      // now matches the ephemeral Price we created for phase 2. Stripe
      // doesn't send one clean "your scheduled change applied" event, so
      // this match against pending_plan_price_id is how it's detected.
      const currentPriceId = subscription.items.data[0]?.price?.id;
      if (currentPriceId) {
        const { data: scheduled } = await admin.from("clients")
          .select("profile_id, pending_plan_id, membership_plan_id, plans")
          .eq("stripe_subscription_id", subscription.id)
          .eq("pending_plan_price_id", currentPriceId)
          .maybeSingle();
        if (scheduled?.pending_plan_id) {
          const { data: incomingRow } = await admin.from("membership_plans")
            .select("data").eq("id", scheduled.pending_plan_id).maybeSingle();
          const { error } = await admin.from("clients").update({
            membership_plan_id: scheduled.pending_plan_id,
            // Same swap as an immediate change — the outgoing membership
            // stops being "held", the incoming one starts, packages stay.
            plans: swapMembershipEnrollment(scheduled.plans, scheduled.membership_plan_id, scheduled.pending_plan_id, incomingRow?.data?.termMonths ?? null),
            pending_plan_id: null, pending_plan_effective_at: null, pending_plan_price_id: null, stripe_schedule_id: null,
          }).eq("profile_id", scheduled.profile_id);
          if (error) throw error;
          console.log(`stripe-webhook: scheduled plan change applied for ${scheduled.profile_id} -> ${scheduled.pending_plan_id}`);
        }
      }

      // Case 2 — a freeze's pause_collection.resumes_at just passed and
      // Stripe auto-resumed billing on its own. If our side still thinks
      // this client is frozen, catch up: bank the elapsed days (same math
      // as unfreeze-membership) and clear the freeze fields.
      if (!subscription.pause_collection) {
        const { data: stillFrozen } = await admin.from("clients")
          .select("profile_id, membership_paused, membership_paused_at, membership_paused_days")
          .eq("stripe_subscription_id", subscription.id)
          .eq("membership_paused", true)
          .maybeSingle();
        if (stillFrozen) {
          const bankedSoFar = stillFrozen.membership_paused_days || 0;
          const elapsedDays = stillFrozen.membership_paused_at
            ? Math.max(0, Math.round((Date.now() - new Date(stillFrozen.membership_paused_at + "T00:00:00Z").getTime()) / 86400000))
            : 0;
          const { error } = await admin.from("clients").update({
            membership_paused: false, membership_paused_at: null, membership_freeze_ends_at: null,
            membership_paused_days: bankedSoFar + elapsedDays,
          }).eq("profile_id", stillFrozen.profile_id);
          if (error) throw error;
          console.log(`stripe-webhook: freeze auto-resumed by Stripe for ${stillFrozen.profile_id}`);
        }
      }
    } else if (event.type === "invoice.payment_failed") {
      // NO AUTO-RETRY: this fires once per attempt and we act on the FIRST
      // failure as final — we never wait for Stripe's own retries to
      // exhaust. Smart Retries must also be turned off in the Stripe
      // Dashboard (see supabase/STRIPE_SETUP.md) so Stripe itself doesn't
      // silently retry the charge in the background behind this app's back.
      const invoice = event.data.object as Stripe.Invoice;
      const subscriptionId = typeof invoice.subscription === "string" ? invoice.subscription : (invoice.subscription as Stripe.Subscription | null)?.id ?? null;
      if (subscriptionId) {
        const clientRow = await clientBySubscription(admin, subscriptionId, "profile_id, membership_plan_id, stripe_subscription_id, sms_opt_in, plans");
        if (clientRow?.profile_id) {
          // Name the plan this subscription is actually for — the primary
          // slot's, or an additional membership's own.
          const failedPlanId = clientRow.stripe_subscription_id === subscriptionId
            ? clientRow.membership_plan_id
            : (clientRow.plans ?? []).find((e: any) => e?.subscriptionId === subscriptionId)?.planId ?? clientRow.membership_plan_id;
          clientRow.membership_plan_id = failedPlanId;
          const amountDue = invoice.amount_due ?? 0;
          const { error: flagErr } = await admin.from("clients").update({
            has_outstanding_balance: true,
            outstanding_balance_cents: amountDue,
            outstanding_invoice_id: invoice.id,
            outstanding_invoice_url: invoice.hosted_invoice_url ?? null,
            outstanding_since: new Date().toISOString(),
          }).eq("profile_id", clientRow.profile_id);
          if (flagErr) throw flagErr;

          const { data: profile } = await admin.from("profiles").select("name, phone").eq("id", clientRow.profile_id).maybeSingle();
          const { data: planRow } = clientRow.membership_plan_id
            ? await admin.from("membership_plans").select("data").eq("id", clientRow.membership_plan_id).maybeSingle()
            : { data: null };
          const plan = planRow?.data;
          const date = new Date().toISOString().slice(0, 10);
          const at = new Date().toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
          // Flag-only entry (amount left null, like the existing
          // late-cancel/no-show rows) — a permanent record it happened
          // without counting as real revenue anywhere in Reports.
          const { error: chargeErr } = await admin.from("charges").insert({
            client_id: clientRow.profile_id,
            client_name: profile?.name || "",
            type: "payment_failed",
            date, at,
            category: plan?.name || null,
            description: `Payment of $${(amountDue / 100).toFixed(2)} failed`,
            plan_id: clientRow.membership_plan_id || null,
            plan_name: plan?.name || null,
          });
          if (chargeErr) throw chargeErr;

          console.log(`stripe-webhook: payment failed for ${clientRow.profile_id}, invoice ${invoice.id}`);

          // Notifications spec — "Failed payment" (SMS). Requires the
          // client's own opt-in (clients.sms_opt_in) AND Twilio secrets to
          // actually be set — sendSms no-ops quietly otherwise, so this is
          // safe to leave deployed before either exists.
          if (clientRow.sms_opt_in && profile?.phone) {
            try {
              await sendSms(
                profile.phone,
                `ONE Fitness: Your payment of $${(amountDue / 100).toFixed(2)} for ${plan?.name || "your membership"} failed. Please update your payment method in the app to avoid a lapse.`,
              );
            } catch (smsErr) {
              console.error("stripe-webhook: failed-payment SMS failed:", smsErr instanceof Error ? smsErr.message : String(smsErr));
            }
          }
        }
      }
    } else if (event.type === "invoice.created") {
      // Notifications spec — "Invoice generated". Requires "invoice.created"
      // to actually be added to this webhook's subscribed events in the
      // Stripe Dashboard (see supabase/STRIPE_SETUP.md) — Stripe only
      // delivers event types a webhook endpoint is explicitly subscribed
      // to, so this branch is inert (never invoked) until that's done.
      const invoice = event.data.object as Stripe.Invoice;
      const subscriptionId = typeof invoice.subscription === "string" ? invoice.subscription : (invoice.subscription as Stripe.Subscription | null)?.id ?? null;
      if (subscriptionId) {
        const clientRow = await clientBySubscription(admin, subscriptionId, "profile_id");
        if (clientRow?.profile_id) {
          const { data: profile } = await admin.from("profiles").select("name, email").eq("id", clientRow.profile_id).maybeSingle();
          if (profile?.email) {
            const dueDate = invoice.due_date ? new Date(invoice.due_date * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : null;
            try {
              await sendEmail(
                profile.email,
                "A new invoice is ready",
                `Hi ${profile.name || "there"},\n\n` +
                  `A new invoice for $${((invoice.amount_due ?? 0) / 100).toFixed(2)} has been generated${dueDate ? `, due ${dueDate}` : ""}.` +
                  `${invoice.hosted_invoice_url ? `\n\nView it here: ${invoice.hosted_invoice_url}` : ""}` +
                  `\n\n— ONE Fitness`,
              );
            } catch (emailErr) {
              console.error("stripe-webhook: invoice-generated email failed:", emailErr instanceof Error ? emailErr.message : String(emailErr));
            }
          }
        }
      }
    } else if (event.type === "invoice.paid") {
      const invoice = event.data.object as Stripe.Invoice;
      const subscriptionId = typeof invoice.subscription === "string" ? invoice.subscription : (invoice.subscription as Stripe.Subscription | null)?.id ?? null;
      if (subscriptionId) {
        // Clears an outstanding balance once it's actually settled — either
        // the client paid the same failed invoice via its hosted link, or a
        // later renewal succeeded. Only acts if the flag was actually set;
        // a normal renewal on an account with no outstanding balance is a
        // complete no-op here.
        const clientRow = await clientBySubscription(admin, subscriptionId, "profile_id, has_outstanding_balance");
        if (clientRow?.profile_id && clientRow.has_outstanding_balance) {
          const { error } = await admin.from("clients").update({
            has_outstanding_balance: false, outstanding_balance_cents: null,
            outstanding_invoice_id: null, outstanding_invoice_url: null, outstanding_since: null,
          }).eq("profile_id", clientRow.profile_id);
          if (error) throw error;
          console.log(`stripe-webhook: outstanding balance cleared for ${clientRow.profile_id}`);
        }

        // Notifications spec — "Membership renewal reminder". Interpreted
        // here as a renewal CONFIRMATION, fired the moment Stripe actually
        // renews the subscription — `billing_reason: "subscription_cycle"`
        // is Stripe's own marker that this invoice came from the normal
        // recurring cycle, not the first-ever payment (that's
        // "subscription_create", handled separately by checkout.session.
        // completed) or a plan-change proration. Independent of the
        // outstanding-balance branch above — fires on every normal renewal.
        if (invoice.billing_reason === "subscription_cycle") {
          const renewingClient = await clientBySubscription(admin, subscriptionId, "profile_id, membership_plan_id, plans");
          if (renewingClient?.profile_id) {
            await applyRollover(admin, renewingClient, subscriptionId);
            try {
              await pushToProfile(renewingClient.profile_id, "Membership renewed", `Your membership just renewed — $${((invoice.amount_paid ?? 0) / 100).toFixed(2)} charged.`);
            } catch (pushErr) {
              console.error("stripe-webhook: renewal push failed:", pushErr instanceof Error ? pushErr.message : String(pushErr));
            }
          }
        }
      }
    }
    return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("stripe-webhook: processing failed:", message);
    // A real failure, not a duplicate — remove the event id we recorded
    // above so Stripe's automatic retry gets processed for real instead of
    // being swallowed as "already handled".
    await admin.from("stripe_processed_events").delete().eq("id", event.id);
    return new Response(JSON.stringify({ error: message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
