// Finding which Stripe subscription a payment or invoice belongs to.
//
// Stripe moved these fields in API version 2025-03-31 ("basil"). Webhook
// event payloads use the endpoint's API version, not the SDK's, so the same
// object can arrive in either shape:
//   - PaymentIntent.invoice was removed.
//   - Invoice.subscription moved to invoice.parent.subscription_details.subscription.
//   - Invoice.subscription_details.metadata moved to
//     invoice.parent.subscription_details.metadata.
// Every reader here accepts both shapes, and a value can be an id string or
// an expanded object.

function idOf(value) {
  if (typeof value === "string" && value) return value;
  if (value && typeof value === "object" && typeof value.id === "string" && value.id) return value.id;
  return null;
}

/** The subscription id on an invoice, in either API shape. */
export function subscriptionIdFromInvoice(invoice) {
  if (!invoice || typeof invoice !== "object") return null;
  return idOf(invoice.subscription)
    ?? idOf(invoice.parent?.subscription_details?.subscription)
    ?? idOf(invoice.subscription_details?.subscription)
    ?? null;
}

/** The subscription's own metadata as copied onto an invoice, in either API shape. */
export function subscriptionMetadataFromInvoice(invoice) {
  if (!invoice || typeof invoice !== "object") return {};
  return invoice.parent?.subscription_details?.metadata
    ?? invoice.subscription_details?.metadata
    ?? {};
}

/** The invoice id on a PaymentIntent. Null on API versions that removed the field. */
export function invoiceIdFromPaymentIntent(pi) {
  if (!pi || typeof pi !== "object") return null;
  return idOf(pi.invoice);
}

/**
 * The subscription a PaymentIntent paid for, or null for a one-time payment.
 *
 * Order, cheapest and most reliable first:
 *   1. metadata.subscription_id, written by create-payment-intent.
 *   2. The invoice on the event's PaymentIntent, when the event still has
 *      one (older endpoint API versions). Saves a call.
 *   3. The invoice on the PaymentIntent re-read through the SDK, which is
 *      pinned to an API version that still has PaymentIntent.invoice.
 * For 2 and 3 the invoice is read and its subscription taken in either shape.
 * An embedded invoice object that already carries the subscription is used
 * without another call.
 *
 * deps.retrievePaymentIntent(id) and deps.retrieveInvoice(id) are the Stripe
 * SDK calls. A failed call is logged through deps.log and the next source is
 * tried, so this never throws.
 *
 * Returns { subscriptionId, source } where source is one of
 * "metadata" | "event_invoice" | "refetched_invoice" | null.
 */
export async function resolveSubscriptionId(pi, deps = {}) {
  const log = deps.log ?? (() => {});
  const fromMeta = typeof pi?.metadata?.subscription_id === "string" ? pi.metadata.subscription_id.trim() : "";
  if (fromMeta) return { subscriptionId: fromMeta, source: "metadata" };

  const fromInvoiceRef = async (ref, source) => {
    const embedded = ref && typeof ref === "object" ? subscriptionIdFromInvoice(ref) : null;
    if (embedded) return { subscriptionId: embedded, source };
    const invoiceId = idOf(ref);
    if (!invoiceId || !deps.retrieveInvoice) return null;
    try {
      const sub = subscriptionIdFromInvoice(await deps.retrieveInvoice(invoiceId));
      return sub ? { subscriptionId: sub, source } : null;
    } catch (e) {
      log(`couldn't read invoice ${invoiceId}: ${e instanceof Error ? e.message : String(e)}`);
      return null;
    }
  };

  const fromEvent = await fromInvoiceRef(pi?.invoice, "event_invoice");
  if (fromEvent) return fromEvent;

  if (pi?.id && deps.retrievePaymentIntent) {
    try {
      const fresh = await deps.retrievePaymentIntent(pi.id);
      const fromFresh = await fromInvoiceRef(fresh?.invoice, "refetched_invoice");
      if (fromFresh) return fromFresh;
    } catch (e) {
      log(`couldn't re-read payment intent ${pi.id}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  return { subscriptionId: null, source: null };
}

/**
 * Links a subscription to the plan entry it pays for, after the fact.
 *
 * Used when a subscription event arrives for a plan that was granted without
 * its subscription id. Only an active entry for planId with no
 * subscriptionId is filled in. An entry already linked to a different
 * subscription is never overwritten. The primary slot gets the id too when
 * it holds that plan and has none.
 *
 * Returns null when nothing needs to change, otherwise the update to write:
 * { plans, stripe_subscription_id? }.
 */
export function backfillSubscriptionLink(client, planId, subscriptionId) {
  if (!client || !planId || !subscriptionId) return null;
  const plans = Array.isArray(client.plans) ? client.plans : [];
  if (plans.some((e) => e?.subscriptionId === subscriptionId)) {
    // Entry already linked. The slot may still be missing it.
    if (plans.some((e) => e?.planId === planId && e?.status === "active" && e?.subscriptionId === subscriptionId)
      && client.membership_plan_id === planId && !client.stripe_subscription_id) {
      return { plans, stripe_subscription_id: subscriptionId };
    }
    return null;
  }
  const idx = plans.findIndex((e) => e?.planId === planId && e?.status === "active" && !e?.subscriptionId);
  if (idx === -1) return null;
  const nextPlans = plans.map((e, i) => (i === idx ? { ...e, subscriptionId } : e));
  const update = { plans: nextPlans };
  if (client.membership_plan_id === planId && !client.stripe_subscription_id) {
    update.stripe_subscription_id = subscriptionId;
  }
  return update;
}

/**
 * Whether a new purchase takes the client's primary slot.
 *
 * - Programs never do.
 * - An empty slot, or re-buying the plan already in it, always does.
 * - A membership takes the slot from anything that isn't a paid membership.
 * - The slot counts as a paid membership when it has a subscription id, or
 *   when its plan was paid for in this app (a purchase charge with a Stripe
 *   payment on or after that plan's start). The second test matters when a
 *   subscription id is missing: a paid membership bought earlier the same
 *   day must not be pushed out by the next one.
 * - A package only takes an empty slot.
 */
export function decideTakesSlot({ planId, isProgram, isMembership, slotPlanId, slotSubscriptionId, slotPaidInApp }) {
  if (isProgram) return false;
  if (!slotPlanId || slotPlanId === planId) return true;
  if (!isMembership) return false;
  const slotIsPaid = !!slotSubscriptionId || !!slotPaidInApp;
  return !slotIsPaid;
}
