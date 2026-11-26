// Stripe Checkout for a paid plan. The in-app payment sheet is the normal
// path; this remains the hosted fallback.
//
// Live function, plus the ghost-plan check. Not deployed by this change.
// A client cannot check out a ghost or archived plan. Staff purchasing for
// a client can check out a ghost plan.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCoachPermission } from "../_shared/coachPermissions.ts";
import { replayLedger, planRedemption, pointsToDiscountCents, REWARD_MAX_REDEEM_POINTS, REWARD_MIN_REDEEM_POINTS } from "../_shared/pointsLedger.ts";
import { assertPlanContractSigned } from "../_shared/planContract.ts";
import { assertPlanOnSale } from "../_shared/planSalesWindow.ts";
import { assertPlanPurchasable } from "../_shared/planVisibility.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
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
    const { planId, returnUrl, paymentMethod, referralEmail, couponCode, targetClientId } = await req.json();
    if (!planId) throw new Error("planId is required");
    const method = paymentMethod === "ach" ? "ach" : "card";

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

    let beneficiaryId = user.id;
    let beneficiaryEmail: string | null | undefined = user.email;
    let purchasedByStaffId: string | null = null;
    if (targetClientId && targetClientId !== user.id) {
      const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (callerProfile?.role !== "owner" && callerProfile?.role !== "coach") {
        throw new Error("Only a coach or owner can purchase a plan on behalf of a client.");
      }
      await requireCoachPermission(admin, user.id, callerProfile.role, "edit_plans");
      const { data: targetProfile } = await admin.from("profiles").select("email").eq("id", targetClientId).maybeSingle();
      if (!targetProfile) throw new Error("Client not found.");
      beneficiaryId = targetClientId;
      beneficiaryEmail = targetProfile.email as string | null;
      purchasedByStaffId = user.id;
    }

    const { data: planRow, error: planErr } = await admin.from("membership_plans").select("data").eq("id", planId).maybeSingle();
    if (planErr) throw planErr;
    const plan = planRow?.data;
    if (!plan) throw new Error("Plan not found.");
    assertPlanOnSale(plan);
    assertPlanPurchasable(plan, { staffEnrollingClient: purchasedByStaffId != null });
    const priceCents = plan.priceCents || 0;
    if (priceCents <= 0) throw new Error("This plan is free — it doesn't need a Stripe checkout.");
    await assertPlanContractSigned(admin, beneficiaryId, planId, {
      staffPurchasingForClient: purchasedByStaffId != null,
    });

    const isProgramPlan = plan.kind === "program" || plan.kind === "nutritionProgram";
    const isSubscription = !isProgramPlan &&
      (plan.paymentType || (plan.kind === "package" ? "one-time" : "subscription")) === "subscription";

    const { data: settingsRow } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
    const paymentSettings = settingsRow?.data?.payments || {};
    if (method === "ach" && !paymentSettings.achOffered) throw new Error("Bank transfer isn't offered — pay by card instead.");

    const feeConfig = method === "ach" ? paymentSettings.achFee : paymentSettings.cardFee;
    const feeCents = calculateFeeCents(priceCents, feeConfig);
    const feeLabel = feeConfig?.label || (method === "ach" ? "Bank Transfer Fee" : "Card Processing Fee");

    const { data: clientRow, error: clientErr } = await admin.from("clients")
      .select("stripe_customer_id, redeem_points_next_renewal, referred_by_trainer_id, billing_anchor_day")
      .eq("profile_id", beneficiaryId).maybeSingle();
    if (clientErr) throw clientErr;

    let referralSurchargeCents = 0;
    let referringTrainerId: string | null = null;
    if (clientRow?.referred_by_trainer_id) {
      const { data: referringTrainer } = await admin.from("trainers")
        .select("referral_commission_percent").eq("profile_id", clientRow.referred_by_trainer_id).maybeSingle();
      const pct = referringTrainer?.referral_commission_percent || 0;
      if (pct > 0) {
        referralSurchargeCents = Math.round(priceCents * (pct / 100));
        referringTrainerId = clientRow.referred_by_trainer_id;
      }
    }

    let customerId = clientRow?.stripe_customer_id || null;
    if (!customerId || !(await customerIsUsable(stripe, customerId))) {
      const customer = await stripe.customers.create({
        email: beneficiaryEmail ?? undefined,
        metadata: { profile_id: beneficiaryId },
      });
      customerId = customer.id;
      await admin.from("clients").update({ stripe_customer_id: customerId }).eq("profile_id", beneficiaryId);
    }

    let redeemedPoints = 0;
    let discountCents = 0;
    let couponId: string | null = null;
    let appliedCouponCode: string | null = null;
    if (typeof couponCode === "string" && couponCode.trim()) {
      const { data: couponRows } = await admin.from("coupons").select("data");
      const match = (couponRows || [])
        .map((r: { data: Record<string, unknown> }) => r.data)
        .find((c: Record<string, unknown>) =>
          !c.archived && typeof c.code === "string" && c.code.toUpperCase() === couponCode.trim().toUpperCase());
      if (!match) throw new Error("That coupon code isn't valid or is no longer active.");
      discountCents = match.type === "flat"
        ? Math.min(Number(match.flatOffCents) || 0, priceCents)
        : Math.round(priceCents * ((Number(match.percentOff) || 0) / 100));
      if (discountCents > 0) {
        const coupon = await stripe.coupons.create({
          amount_off: discountCents,
          currency: "usd",
          duration: "once",
          name: `Coupon: ${match.code}`,
        });
        couponId = coupon.id;
        appliedCouponCode = match.code as string;
      }
    } else if (clientRow?.redeem_points_next_renewal) {
      const { data: ledgerRows } = await admin.from("points_ledger").select("*").eq("client_id", beneficiaryId);
      const { lots } = replayLedger(ledgerRows || []);
      const redemption = planRedemption(lots, new Date(), { capPoints: REWARD_MAX_REDEEM_POINTS, minPoints: REWARD_MIN_REDEEM_POINTS });
      if (redemption) {
        redeemedPoints = redemption.points;
        discountCents = Math.min(pointsToDiscountCents(redeemedPoints, priceCents), priceCents);
        if (discountCents > 0) {
          const coupon = await stripe.coupons.create({
            amount_off: discountCents,
            currency: "usd",
            duration: "once",
            name: `ONE Fitness rewards (${redeemedPoints} pts)`,
          });
          couponId = coupon.id;
        }
      }
    }

    const recurring = isSubscription ? { interval: "month" as const, interval_count: plan.billingIntervalMonths || 1 } : undefined;
    const lineItems = [{
      quantity: 1,
      price_data: {
        currency: "usd",
        unit_amount: priceCents,
        product_data: { name: plan.name || "Membership Plan" },
        ...(recurring ? { recurring } : {}),
      },
    }];
    if (feeCents > 0) {
      lineItems.push({
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: feeCents,
          product_data: { name: feeLabel },
          ...(recurring ? { recurring } : {}),
        },
      });
    }
    if (referralSurchargeCents > 0) {
      lineItems.push({
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: referralSurchargeCents,
          product_data: { name: "Coach Referral Commission" },
          ...(recurring ? { recurring } : {}),
        },
      });
    }

    const cleanReferralEmail = typeof referralEmail === "string" ? referralEmail.trim().toLowerCase() : "";
    const isSelfReferral = cleanReferralEmail && beneficiaryEmail && cleanReferralEmail === beneficiaryEmail.toLowerCase();

    const anchorDay = clientRow?.billing_anchor_day || paymentSettings.defaultBillingAnchorDay || null;
    let billingCycleAnchorTimestamp: number | null = null;
    if (isSubscription && anchorDay) {
      const now = new Date();
      const y = now.getUTCFullYear();
      const m = now.getUTCMonth();
      const candidate = new Date(Date.UTC(y, m, anchorDay, 0, 0, 0));
      const target = candidate.getTime() > now.getTime() ? candidate : new Date(Date.UTC(y, m + 1, anchorDay, 0, 0, 0));
      billingCycleAnchorTimestamp = Math.floor(target.getTime() / 1000);
    }

    const origin = returnUrl || Deno.env.get("APP_URL") || "https://example.com";
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: isSubscription ? "subscription" : "payment",
      payment_method_types: method === "ach" ? ["us_bank_account"] : ["card"],
      line_items: lineItems,
      ...(couponId ? { discounts: [{ coupon: couponId }] } : {}),
      success_url: `${origin}?stripe=success&plan=${encodeURIComponent(planId)}`,
      cancel_url: `${origin}?stripe=cancel`,
      metadata: {
        profile_id: beneficiaryId,
        plan_id: planId,
        subtotal_cents: String(priceCents),
        fee_cents: String(feeCents),
        redeemed_points: String(redeemedPoints),
        ...(cleanReferralEmail && !isSelfReferral ? { referral_email: cleanReferralEmail } : {}),
        ...(referringTrainerId ? { referring_trainer_id: referringTrainerId, surcharge_cents: String(referralSurchargeCents) } : {}),
        ...(appliedCouponCode ? { coupon_code: appliedCouponCode } : {}),
        ...(purchasedByStaffId ? { purchased_by_staff_id: purchasedByStaffId } : {}),
      },
      ...(isSubscription
        ? {
          subscription_data: {
            metadata: { profile_id: beneficiaryId, plan_id: planId },
            ...(billingCycleAnchorTimestamp ? { billing_cycle_anchor: billingCycleAnchorTimestamp } : {}),
          },
        }
        : {}),
      ...(feeCents > 0 && paymentSettings.checkoutDisclosureText
        ? { custom_text: { submit: { message: String(paymentSettings.checkoutDisclosureText).slice(0, 1200) } } }
        : {}),
    });

    return new Response(JSON.stringify({ url: session.url }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("create-checkout-session failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
