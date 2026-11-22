// In-app payments. Card data never touches this server.
//
// Proposed replacement. Not deployed until you deploy this function.
// The only behavior change from the live function: priceOverrideCents is
// accepted from the owner only. A coach can still buy a catalogue plan for
// a client and can still pass a coupon code. They cannot type an amount.
//
// fullFirstCharge (owner only): on a monthly membership with a billing day,
// the first invoice charges the full price instead of the prorated amount.
// The next charge is still the next billing day, so the subscription's
// trial_end, recurring items and billing anchor are unchanged.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger, planRedemption, pointsToDiscountCents } from "../_shared/pointsLedger.ts";
import { ensureProduct } from "../_shared/stripeProduct.ts";
import { assertPlanContractSigned } from "../_shared/planContract.ts";
import { assertPlanOnSale } from "../_shared/planSalesWindow.ts";
import { assertPlanPurchasable } from "../_shared/planVisibility.mjs";
import {
  effectivePackageMax,
  renewalDiscountCents,
  renewalIdempotencyKey,
  renewalOffer,
  renewalOfferFromSettings,
} from "../_shared/packageRenewal.ts";
import { discountCents as couponDiscountCents, firstChargePlanCents, firstChargeSentence, membershipFirstCharge, ongoingDiscountCents } from "../_shared/billingAnchor.mjs";
import { stripeCouponDuration } from "../_shared/couponDuration.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const STRIPE_API_VERSION = "2024-06-20";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: STRIPE_API_VERSION,
  httpClient: Stripe.createFetchHttpClient(),
});

// deno-lint-ignore no-explicit-any
function calculateFeeCents(subtotalCents: number, feeConfig: any): number {
  if (!feeConfig?.enabled || subtotalCents <= 0) return 0;
  const pct = feeConfig.structure === "flat" ? 0 : Math.round(subtotalCents * (feeConfig.percent / 100));
  const flat = feeConfig.structure === "percentage" ? 0 : feeConfig.flatCents;
  return pct + flat;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { planId, couponCode, targetClientId, paymentMethod, priceOverrideCents, accessExpiresAt, renewalEnrollmentStart, fullFirstCharge } = await req.json();
    if (!planId) throw new Error("planId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

    let buyerId = user.id;
    const wantsStaffPowers =
      (targetClientId && targetClientId !== user.id) ||
      priceOverrideCents != null ||
      accessExpiresAt != null ||
      fullFirstCharge === true;

    let callerIsStaff = false;
    let callerRole = "";
    if (wantsStaffPowers) {
      const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      callerRole = me?.role ?? "";
      callerIsStaff = callerRole === "owner" || callerRole === "coach";
    }

    if (targetClientId && targetClientId !== user.id) {
      if (!callerIsStaff) throw new Error("Only a coach or owner can purchase on behalf of a client.");
      buyerId = targetClientId;
    }

    if (priceOverrideCents != null && callerRole !== "owner") {
      throw new Error("Only the owner can change the price. Charge the plan's set price, or apply a coupon.");
    }
    // Checked against the signed-in caller, never the client being billed.
    if (fullFirstCharge === true && callerRole !== "owner") {
      throw new Error("Only the owner can charge the full price up front.");
    }
    const wantsFullFirstCharge = fullFirstCharge === true && callerRole === "owner";
    if (accessExpiresAt != null && !callerIsStaff) {
      throw new Error("Only a coach or owner can set an expiry date.");
    }

    const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", planId).maybeSingle();
    const plan = planRow?.data;
    if (!plan) throw new Error("Plan not found.");
    assertPlanOnSale(plan);
    const overrideCents = priceOverrideCents == null ? null : Math.round(Number(priceOverrideCents));
    if (overrideCents != null && (!Number.isFinite(overrideCents) || overrideCents < 0)) {
      throw new Error("That price isn't a valid amount.");
    }
    const priceCents = overrideCents ?? (plan.priceCents || 0);
    if (priceCents <= 0) {
      throw new Error(
        overrideCents != null
          ? "A price of zero can't be taken as a payment — assign the plan for free instead."
          : "This plan is free — it doesn't need a payment.",
      );
    }
    await assertPlanContractSigned(admin, buyerId, planId, {
      staffPurchasingForClient: callerIsStaff && buyerId !== user.id,
    });

    const kind = plan.kind || "membership";
    const isSubscription = (plan.paymentType || (kind === "package" ? "one-time" : "subscription")) === "subscription";
    const isPackage = kind === "package";
    const stripeMethodTypes = ["card", "us_bank_account"];
    const allowedMethods = { card: true, ach: true, applePay: isPackage };

    const { data: settingsRow, error: settingsErr } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
    const paymentSettings = settingsRow?.data?.payments || {};
    const method = paymentMethod === "ach" ? "ach" : "card";
    const feeConfig = method === "ach" ? paymentSettings.achFee : paymentSettings.cardFee;
    const feeCents = calculateFeeCents(priceCents, feeConfig);

    const { data: clientRow } = await admin.from("clients")
      .select("stripe_customer_id, redeem_points_next_renewal, referred_by_trainer_id, billing_anchor_day, membership_plan_id, plans, session_count_override, session_count_override_month")
      .eq("profile_id", buyerId).maybeSingle();

    let referralSurchargeCents = 0;
    let referralPercent = 0;
    let referringTrainerId: string | null = null;
    if (clientRow?.referred_by_trainer_id) {
      const { data: referringTrainer } = await admin.from("trainers")
        .select("referral_commission_percent").eq("profile_id", clientRow.referred_by_trainer_id).maybeSingle();
      const pct = referringTrainer?.referral_commission_percent || 0;
      if (pct > 0) {
        referralPercent = pct;
        referralSurchargeCents = Math.round(priceCents * (pct / 100));
        referringTrainerId = clientRow.referred_by_trainer_id;
      }
    }

    const { data: buyerProfile } = await admin.from("profiles").select("email, name").eq("id", buyerId).maybeSingle();

    let customerId = clientRow?.stripe_customer_id || null;
    if (!customerId || !(await customerIsUsable(stripe, customerId))) {
      const customer = await stripe.customers.create({
        email: buyerProfile?.email ?? undefined,
        name: buyerProfile?.name ?? undefined,
        metadata: { profile_id: buyerId },
      });
      customerId = customer.id;
      await admin.from("clients").update({ stripe_customer_id: customerId }).eq("profile_id", buyerId);
    }

    let discountCents = 0;
    let redeemedPoints = 0;
    let appliedCouponCode: string | null = null;
    // deno-lint-ignore no-explicit-any
    let appliedCoupon: any = null;
    let stripeCouponId: string | null = null;
    let renewalKey: string | null = null;
    let renewalOfferName: "discount" | "full" | null = null;
    let renewalConfig: ReturnType<typeof renewalOfferFromSettings> | null = null;
    const renewalStart = typeof renewalEnrollmentStart === "string" ? renewalEnrollmentStart.slice(0, 10) : "";
    // A renewal is the package the client already holds, so a ghost package
    // still renews. A new purchase of a ghost plan is refused unless staff
    // are enrolling the client. The renewal branch below checks they hold it.
    if (!renewalStart) {
      assertPlanPurchasable(plan, { staffEnrollingClient: callerIsStaff && buyerId !== user.id });
    }

    const rawCode = typeof couponCode === "string" ? couponCode.trim() : "";
    if (renewalStart) {
      if (buyerId !== user.id) throw new Error("A renewal is confirmed by the client on their own card.");
      if (!isPackage || isSubscription) throw new Error("That renewal is for a session package.");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(renewalStart)) throw new Error("That package was not found.");
      const heldPlans = Array.isArray(clientRow?.plans) ? clientRow.plans : [];
      const held = heldPlans.find((e: { status?: string; planId?: string; startDate?: string }) =>
        e?.status === "active" && e?.planId === planId && String(e?.startDate || "").slice(0, 10) === renewalStart
      );
      if (!held) throw new Error("That package is not on your account.");
      assertPlanPurchasable(plan, { renewingHeldPlan: true });

      const { count: usedCount } = await admin.from("bookings")
        .select("id", { count: "exact", head: true })
        .eq("client_id", buyerId)
        .eq("plan_id", planId)
        .in("attendance_status", ["checked-in", "no-show"])
        .is("cancelled_at", null);
      const todayMonth = new Intl.DateTimeFormat("en-CA", {
        timeZone: "America/Los_Angeles",
        year: "numeric",
        month: "2-digit",
      }).format(new Date()).slice(0, 7);
      const maxSessions = effectivePackageMax(plan, held, todayMonth, {
        value: clientRow?.session_count_override == null ? null : Number(clientRow.session_count_override),
        month: clientRow?.session_count_override_month ?? null,
        applies: clientRow?.membership_plan_id === planId,
      });
      const remaining = Math.max(0, maxSessions - (usedCount || 0));

      const { data: alreadyPaid } = await admin.from("package_renewal_charges")
        .select("payment_intent_id")
        .eq("client_id", buyerId)
        .eq("plan_id", planId)
        .eq("enrollment_start", renewalStart)
        .eq("status", "succeeded")
        .maybeSingle();
      if (alreadyPaid) {
        return new Response(JSON.stringify({
          alreadyRenewed: true,
          requiresPayment: false,
          mode: "payment",
          paymentIntentId: alreadyPaid.payment_intent_id ?? null,
        }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
      }

      const { data: discountNotice } = await admin.from("client_notices")
        .select("forfeited")
        .eq("client_id", buyerId)
        .eq("kind", "package_discount")
        .eq("plan_id", planId)
        .eq("enrollment_start", renewalStart)
        .maybeSingle();
      // The percent is read here. A percent on the request is ignored.
      if (settingsErr) throw new Error("Couldn't read the renewal offer. Please try again.");
      renewalConfig = renewalOfferFromSettings(settingsRow?.data);
      const offer = renewalOffer(remaining, maxSessions, priceCents, discountNotice?.forfeited === true, false, renewalConfig);
      if (offer === "none") throw new Error("This package does not have a renewal offer right now.");
      if (offer === "discount") discountCents = renewalDiscountCents(priceCents, renewalConfig.percent);
      renewalOfferName = offer;
      renewalKey = renewalIdempotencyKey(buyerId, planId, renewalStart, offer);
      const expectedAmount = Math.max(0, priceCents - discountCents) + feeCents + referralSurchargeCents;

      const { data: started } = await admin.from("package_renewal_charges")
        .select("payment_intent_id, attempt")
        .eq("idempotency_key", renewalKey)
        .maybeSingle();
      if (started?.payment_intent_id) {
        const prev = await stripe.paymentIntents.retrieve(started.payment_intent_id);
        if (prev.status === "succeeded") {
          await admin.from("package_renewal_charges").update({
            status: "succeeded",
            confirmed_at: new Date().toISOString(),
          }).eq("idempotency_key", renewalKey);
          return new Response(JSON.stringify({
            alreadyRenewed: true,
            requiresPayment: false,
            mode: "payment",
            paymentIntentId: prev.id,
          }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
        }
        // A retry of the same offer reuses this key. If the owner changed
        // the discount after a charge was started, that old amount is
        // cancelled and a new charge is opened at the saved price.
        const staleAmount = prev.amount !== expectedAmount;
        if (prev.status === "canceled" || staleAmount) {
          if (staleAmount && prev.status !== "canceled") {
            if (prev.status === "processing") {
              throw new Error("A renewal payment is already in progress.");
            }
            try {
              await stripe.paymentIntents.cancel(prev.id);
            } catch {
              throw new Error("A renewal payment is already in progress.");
            }
          }
          const attempt = Number(started.attempt || 1) + 1;
          renewalKey = renewalIdempotencyKey(buyerId, planId, renewalStart, offer, attempt);
        }
      }
    } else if (rawCode) {
      const { data: coupons } = await admin.from("coupons").select("data");
      // deno-lint-ignore no-explicit-any
      const match = (coupons ?? []).map((r: any) => r.data).find((c: any) =>
        !c?.archived && String(c?.code ?? "").toUpperCase() === rawCode.toUpperCase()
      );
      if (!match) throw new Error("That coupon code isn't valid or is no longer active.");
      appliedCoupon = match;
      discountCents = match.type === "flat"
        ? Math.min(match.flatOffCents || 0, priceCents)
        : Math.round(priceCents * ((match.percentOff || 0) / 100));
      appliedCouponCode = match.code;
    } else if (clientRow?.redeem_points_next_renewal) {
      const { data: ledgerRows } = await admin.from("points_ledger").select("*").eq("client_id", buyerId);
      const { lots } = replayLedger(ledgerRows || []);
      const redemption = planRedemption(lots, new Date(), { capPoints: 40, minPoints: 40 });
      if (redemption) {
        redeemedPoints = redemption.points;
        discountCents = Math.min(pointsToDiscountCents(redeemedPoints, priceCents), priceCents);
      }
    }

    const metadata: Record<string, string> = {
      profile_id: buyerId,
      plan_id: planId,
      subtotal_cents: String(priceCents),
      fee_cents: String(feeCents),
      discount_cents: String(discountCents),
      redeemed_points: String(redeemedPoints),
      ...(appliedCouponCode ? { coupon_code: appliedCouponCode } : {}),
      ...(referringTrainerId ? { referring_trainer_id: referringTrainerId, surcharge_cents: String(referralSurchargeCents) } : {}),
      ...(buyerId !== user.id ? { purchased_by: user.id } : {}),
      ...(accessExpiresAt ? { access_expires_at: String(accessExpiresAt) } : {}),
      ...(renewalOfferName ? {
        renewal_offer: renewalOfferName,
        enrollment_start: renewalStart,
        renewal_key: renewalKey || "",
        ...(renewalOfferName === "discount" && renewalConfig ? { renewal_percent: String(renewalConfig.percent) } : {}),
      } : {}),
    };

    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customerId },
      { apiVersion: STRIPE_API_VERSION },
    );

    let clientSecret: string | null = null;
    let amountCents = 0;

    if (isSubscription) {
      const planRenewalDay = Number(plan.renewalDay) >= 1 && Number(plan.renewalDay) <= 28 ? Number(plan.renewalDay) : null;
      const anchorDay = clientRow?.billing_anchor_day || planRenewalDay || paymentSettings.defaultBillingAnchorDay || null;
      const monthly = (plan.billingIntervalMonths || 1) === 1;
      const schedule = anchorDay ? membershipFirstCharge(new Date(), priceCents, anchorDay) : null;
      const prorate = !!(schedule && monthly);
      // Owner's "Charge full price now": same discount, fee and surcharge
      // rules below, just on the full price. Only matters when today isn't
      // already the billing day.
      const fullFirst = !!(prorate && wantsFullFirstCharge && !schedule!.fullMonth);
      const firstPlan = schedule && monthly
        ? firstChargePlanCents(schedule, { fullFirstCharge: fullFirst })
        : priceCents;
      if (prorate && appliedCoupon) {
        discountCents = couponDiscountCents(firstPlan, appliedCoupon);
      } else if (prorate && redeemedPoints) {
        discountCents = Math.min(pointsToDiscountCents(redeemedPoints, firstPlan), firstPlan);
      }
      const firstFee = prorate ? calculateFeeCents(firstPlan, feeConfig) : feeCents;
      const firstSurcharge = prorate ? Math.round(firstPlan * (referralPercent / 100)) : referralSurchargeCents;
      const recurringFee = calculateFeeCents(priceCents, feeConfig);
      metadata.subtotal_cents = String(firstPlan);
      metadata.fee_cents = String(firstFee);
      metadata.discount_cents = String(discountCents);
      if (referringTrainerId) metadata.surcharge_cents = String(firstSurcharge);
      if (schedule) {
        metadata.billing_anchor_day = String(schedule.anchorDay);
        metadata.next_charge_on = schedule.nextChargeDate;
      }
      if (fullFirst) metadata.full_first_charge = "true";

      const planProduct = await ensureProduct(stripe, `plan_${planId}`, plan.name || "Membership Plan");
      const firstProduct = prorate && !fullFirst
        ? await ensureProduct(stripe, `plan_${planId}_prorated`, `${plan.name || "Membership"} (prorated)`)
        : planProduct;
      const feeProduct = await ensureProduct(
        stripe,
        `fee_${method}`,
        feeConfig?.label || (method === "ach" ? "Bank Transfer Fee" : "Card Processing Fee"),
      );
      const referralProduct = await ensureProduct(stripe, "coach_referral", "Coach Referral Commission");

      if (appliedCoupon && (discountCents > 0 || appliedCoupon.duration === "forever" || appliedCoupon.duration === "repeating")) {
        const duration = stripeCouponDuration(appliedCoupon);
        const created = await stripe.coupons.create({
          ...duration,
          name: `Coupon ${appliedCouponCode}`,
          applies_to: { products: [...new Set([planProduct, firstProduct])] },
          ...(appliedCoupon.type === "flat"
            ? { amount_off: Math.max(0, Math.round(Number(appliedCoupon.flatOffCents) || 0)), currency: "usd" }
            : { percent_off: Math.min(100, Math.max(0, Math.round(Number(appliedCoupon.percentOff) || 0))) }),
        });
        stripeCouponId = created.id;
      } else if (discountCents > 0) {
        const created = await stripe.coupons.create({
          amount_off: discountCents,
          currency: "usd",
          duration: "once",
          name: `ONE Fitness rewards (${redeemedPoints} pts)`,
        });
        stripeCouponId = created.id;
      }

      const interval = plan.billingIntervalMonths || 1;
      const items = [{
        price_data: {
          currency: "usd",
          unit_amount: priceCents,
          product: planProduct,
          recurring: { interval: "month" as const, interval_count: interval },
        },
      }];
      if (recurringFee > 0) {
        items.push({
          price_data: {
            currency: "usd",
            unit_amount: recurringFee,
            product: feeProduct,
            recurring: { interval: "month" as const, interval_count: interval },
          },
        });
      }
      if (referralSurchargeCents > 0) {
        items.push({
          price_data: {
            currency: "usd",
            unit_amount: referralSurchargeCents,
            product: referralProduct,
            recurring: { interval: "month" as const, interval_count: interval },
          },
        });
      }

      const firstPaymentItems = schedule
        ? [
          { price_data: { currency: "usd", unit_amount: firstPlan, product: firstProduct } },
          ...(firstFee > 0 ? [{ price_data: { currency: "usd", unit_amount: firstFee, product: feeProduct } }] : []),
          ...(firstSurcharge > 0 ? [{ price_data: { currency: "usd", unit_amount: firstSurcharge, product: referralProduct } }] : []),
        ]
        : [];

      const sentenceCoupon = appliedCoupon
        ?? (prorate && discountCents > 0 ? { type: "flat", flatOffCents: discountCents, duration: "once" } : null);
      const receiptText = prorate && schedule ? firstChargeSentence(schedule, sentenceCoupon, { fullFirstCharge: fullFirst }) : null;

      const subscription = await stripe.subscriptions.create({
        customer: customerId,
        items,
        ...(schedule ? { trial_end: schedule.nextChargeUnix, add_invoice_items: firstPaymentItems, description: receiptText ?? undefined } : {}),
        payment_behavior: "default_incomplete",
        payment_settings: {
          save_default_payment_method: "on_subscription",
          payment_method_types: stripeMethodTypes,
        },
        ...(stripeCouponId ? { discounts: [{ coupon: stripeCouponId }] } : {}),
        metadata,
        expand: ["latest_invoice.payment_intent"],
      });

      const invoice = subscription.latest_invoice as Stripe.Invoice;
      const intent = invoice?.payment_intent as Stripe.PaymentIntent | null;
      clientSecret = intent?.client_secret ?? null;
      amountCents = invoice?.amount_due ?? 0;
      if (clientSecret) {
        await stripe.paymentIntents.update(intent!.id, { metadata: { ...metadata, subscription_id: subscription.id }, ...(receiptText ? { description: receiptText } : {}) });
      }

      const nextChargeCents = schedule
        ? priceCents - ongoingDiscountCents(priceCents, appliedCoupon) + recurringFee + referralSurchargeCents
        : priceCents;

      return new Response(JSON.stringify({
        mode: "subscription",
        clientSecret,
        subscriptionId: subscription.id,
        ephemeralKey: ephemeralKey.secret,
        customerId,
        publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
        allowedMethods,
        amountCents,
        requiresPayment: !!clientSecret,
        receiptText,
        proratedCents: schedule && prorate && !fullFirst ? schedule.proratedCents : null,
        fullFirstCharge: fullFirst,
        nextChargeOn: schedule?.nextChargeDate ?? null,
        nextChargeCents: schedule ? nextChargeCents : null,
      }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    amountCents = Math.max(0, priceCents - discountCents) + feeCents + referralSurchargeCents;
    const intent = await stripe.paymentIntents.create({
      amount: amountCents,
      currency: "usd",
      customer: customerId,
      payment_method_types: stripeMethodTypes,
      setup_future_usage: "off_session",
      description: plan.name || "Package",
      metadata,
    }, renewalKey ? { idempotencyKey: renewalKey } : undefined);

    if (renewalKey && renewalOfferName) {
      const attempt = renewalKey.includes(`-${renewalOfferName}-`)
        ? Number(renewalKey.split("-").pop())
        : 1;
      await admin.from("package_renewal_charges").upsert({
        idempotency_key: renewalKey,
        client_id: buyerId,
        plan_id: planId,
        enrollment_start: renewalStart,
        offer: renewalOfferName,
        payment_intent_id: intent.id,
        amount_cents: amountCents,
        status: intent.status === "succeeded" ? "succeeded" : "started",
        attempt: Number.isFinite(attempt) && attempt > 1 ? attempt : 1,
      }, { onConflict: "idempotency_key" });
    }

    return new Response(JSON.stringify({
      mode: "payment",
      clientSecret: intent.client_secret,
      paymentIntentId: intent.id,
      ephemeralKey: ephemeralKey.secret,
      customerId,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      allowedMethods,
      amountCents,
      requiresPayment: true,
      renewalOffer: renewalOfferName,
    }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("create-payment-intent failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
