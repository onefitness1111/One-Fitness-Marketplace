// In-app payments. Card data never touches this server.
//
// Proposed replacement. Not deployed until you deploy this function.
// The only behavior change from the live function: priceOverrideCents is
// accepted from the owner only. A coach can still buy a catalogue plan for
// a client and can still pass a coupon code. They cannot type an amount.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { customerIsUsable } from "../_shared/stripeCustomer.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { replayLedger, planRedemption, pointsToDiscountCents } from "../_shared/pointsLedger.ts";
import { ensureProduct } from "../_shared/stripeProduct.ts";
import { assertPlanContractSigned } from "../_shared/planContract.ts";
import { assertPlanOnSale } from "../_shared/planSalesWindow.ts";

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
    const { planId, couponCode, targetClientId, paymentMethod, priceOverrideCents, accessExpiresAt } = await req.json();
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
      accessExpiresAt != null;

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

    const { data: settingsRow } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
    const paymentSettings = settingsRow?.data?.payments || {};
    const method = paymentMethod === "ach" ? "ach" : "card";
    const feeConfig = method === "ach" ? paymentSettings.achFee : paymentSettings.cardFee;
    const feeCents = calculateFeeCents(priceCents, feeConfig);

    const { data: clientRow } = await admin.from("clients")
      .select("stripe_customer_id, redeem_points_next_renewal, referred_by_trainer_id, billing_anchor_day")
      .eq("profile_id", buyerId).maybeSingle();

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
    let stripeCouponId: string | null = null;

    const rawCode = typeof couponCode === "string" ? couponCode.trim() : "";
    if (rawCode) {
      const { data: coupons } = await admin.from("coupons").select("data");
      // deno-lint-ignore no-explicit-any
      const match = (coupons ?? []).map((r: any) => r.data).find((c: any) =>
        !c?.archived && String(c?.code ?? "").toUpperCase() === rawCode.toUpperCase()
      );
      if (!match) throw new Error("That coupon code isn't valid or is no longer active.");
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
    };

    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customerId },
      { apiVersion: STRIPE_API_VERSION },
    );

    let clientSecret: string | null = null;
    let amountCents = 0;

    if (isSubscription) {
      if (discountCents > 0) {
        const coupon = await stripe.coupons.create({
          amount_off: discountCents,
          currency: "usd",
          duration: "once",
          name: appliedCouponCode ? `Coupon ${appliedCouponCode}` : `ONE Fitness rewards (${redeemedPoints} pts)`,
        });
        stripeCouponId = coupon.id;
      }

      const planRenewalDay = Number(plan.renewalDay) >= 1 && Number(plan.renewalDay) <= 28 ? Number(plan.renewalDay) : null;
      const anchorDay = clientRow?.billing_anchor_day || planRenewalDay || paymentSettings.defaultBillingAnchorDay || null;
      let billingCycleAnchor: number | undefined;
      if (anchorDay) {
        const now = new Date();
        const target = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, anchorDay, 0, 0, 0));
        billingCycleAnchor = Math.floor(target.getTime() / 1000);
      }

      const items = [{
        price_data: {
          currency: "usd",
          unit_amount: priceCents,
          product: await ensureProduct(stripe, `plan_${planId}`, plan.name || "Membership Plan"),
          recurring: { interval: "month" as const, interval_count: plan.billingIntervalMonths || 1 },
        },
      }];
      if (feeCents > 0) {
        items.push({
          price_data: {
            currency: "usd",
            unit_amount: feeCents,
            product: await ensureProduct(stripe, `fee_${method}`, feeConfig?.label || (method === "ach" ? "Bank Transfer Fee" : "Card Processing Fee")),
            recurring: { interval: "month" as const, interval_count: plan.billingIntervalMonths || 1 },
          },
        });
      }
      if (referralSurchargeCents > 0) {
        items.push({
          price_data: {
            currency: "usd",
            unit_amount: referralSurchargeCents,
            product: await ensureProduct(stripe, "coach_referral", "Coach Referral Commission"),
            recurring: { interval: "month" as const, interval_count: plan.billingIntervalMonths || 1 },
          },
        });
      }

      const firstPaymentItems = billingCycleAnchor
        ? items.map((it) => ({
          price_data: { currency: it.price_data.currency, unit_amount: it.price_data.unit_amount, product: it.price_data.product },
        }))
        : [];

      const subscription = await stripe.subscriptions.create({
        customer: customerId,
        items,
        ...(billingCycleAnchor ? { trial_end: billingCycleAnchor, add_invoice_items: firstPaymentItems } : {}),
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
        await stripe.paymentIntents.update(intent!.id, { metadata });
      }

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
    });

    return new Response(JSON.stringify({
      mode: "payment",
      clientSecret: intent.client_secret,
      ephemeralKey: ephemeralKey.secret,
      customerId,
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      allowedMethods,
      amountCents,
      requiresPayment: true,
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
