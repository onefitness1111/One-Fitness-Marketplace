// Starting, scheduling and ending a membership freeze. One copy, used by
// freeze-membership, unfreeze-membership, apply-due-requests and
// stripe-webhook, so every path pauses and resumes the same subscriptions
// and holds the same sessions. The rules are in membershipFreeze.mjs.
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import {
  anchorDayFromStripe,
  applyFreezeHolds,
  clearFreezeHolds,
  daysBetween,
  freezeResumesAt,
  moveFreezeHolds,
  nextBillingOnOrAfter,
  pacificToday,
} from "./membershipFreeze.mjs";

// deno-lint-ignore no-explicit-any
type Admin = any;
// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

export const FREEZE_CLIENT_COLUMNS =
  "profile_id, stripe_subscription_id, stripe_customer_id, plans, membership_plan_id, session_count_override, " +
  "session_count_override_month, billing_anchor_day, membership_paused, membership_paused_at, " +
  "membership_freeze_ends_at, membership_paused_days";

const BILLABLE = new Set(["active", "trialing", "past_due", "unpaid"]);

export async function loadFreezeClient(admin: Admin, clientId: string): Promise<Row | null> {
  const { data, error } = await admin.from("clients").select(FREEZE_CLIENT_COLUMNS).eq("profile_id", clientId).maybeSingle();
  if (error) throw new Error("Couldn't read this client's membership.");
  return data ?? null;
}

/// Every subscription that can bill this client: the primary one, each
/// membership's own, and anything else live on their Stripe customer.
export async function clientSubscriptionIds(stripe: Stripe, client: Row): Promise<string[]> {
  const ids = new Set<string>();
  if (client?.stripe_subscription_id) ids.add(String(client.stripe_subscription_id));
  for (const entry of Array.isArray(client?.plans) ? client.plans : []) {
    if (entry?.subscriptionId && entry?.status === "active") ids.add(String(entry.subscriptionId));
  }
  if (client?.stripe_customer_id) {
    const list = await stripe.subscriptions.list({ customer: String(client.stripe_customer_id), status: "all", limit: 100 });
    for (const sub of list.data) {
      if (BILLABLE.has(sub.status)) ids.add(sub.id);
    }
  }
  return [...ids];
}

/// Pauses every subscription so renewals inside the freeze are voided.
/// Returns the billing day of the month read from the first one, if any.
export async function pauseSubscriptions(stripe: Stripe, ids: string[], endDay: string): Promise<number | null> {
  const resumesAt = freezeResumesAt(endDay);
  let anchorDay: number | null = null;
  for (const id of ids) {
    const sub = await stripe.subscriptions.update(id, {
      pause_collection: { behavior: "void", resumes_at: resumesAt },
    });
    if (anchorDay == null) anchorDay = anchorDayFromStripe(sub?.billing_cycle_anchor);
  }
  return anchorDay;
}

/// Resumes every subscription that is still paused. A failure on one does
/// not stop the rest. Returns how many could not be resumed.
export async function resumeSubscriptions(stripe: Stripe, ids: string[]): Promise<number> {
  let failed = 0;
  for (const id of ids) {
    try {
      const sub = await stripe.subscriptions.retrieve(id);
      if (!sub.pause_collection) continue;
      await stripe.subscriptions.update(id, { pause_collection: "" } as unknown as Stripe.SubscriptionUpdateParams);
    } catch (_e) {
      failed += 1;
      console.warn("freeze: a subscription could not be resumed");
    }
  }
  return failed;
}

async function stripeAnchorDay(stripe: Stripe | null, client: Row): Promise<number | null> {
  if (!stripe || !client?.stripe_subscription_id) return null;
  try {
    const sub = await stripe.subscriptions.retrieve(String(client.stripe_subscription_id));
    return anchorDayFromStripe(sub?.billing_cycle_anchor);
  } catch (_e) {
    return null;
  }
}

function monthAfter(month: string): string {
  const [y, m] = month.split("-").map(Number);
  const next = new Date(Date.UTC(y, m, 1));
  return `${next.getUTCFullYear()}-${String(next.getUTCMonth() + 1).padStart(2, "0")}`;
}

async function holdsFor(admin: Admin, client: Row, frozenFrom: string, heldFrom: string, heldUntil: string): Promise<Row[]> {
  const plans = Array.isArray(client.plans) ? client.plans : [];
  const planIds = plans.filter((e: Row) => e?.status === "active" && e?.planId).map((e: Row) => String(e.planId));
  if (planIds.length === 0) return plans;
  const { data: planRows, error: planErr } = await admin.from("membership_plans").select("id, data").in("id", planIds);
  if (planErr) throw new Error("Couldn't read the client's plans.");
  const planById = new Map<string, Row>();
  for (const row of planRows ?? []) planById.set(String(row.id), { id: row.id, ...(row.data || {}) });

  const month = frozenFrom.slice(0, 7);
  const { data: bookings, error: bookErr } = await admin.from("bookings")
    .select("plan_id, date, attendance_status, cancelled_at, is_physical_assessment")
    .eq("client_id", client.profile_id)
    .gte("date", `${month}-01`)
    .lt("date", `${monthAfter(month)}-01`);
  if (bookErr) throw new Error("Couldn't read the client's bookings.");

  const legacyValue = client.session_count_override == null ? null : Number(client.session_count_override);
  const result = applyFreezeHolds(plans, planById, bookings ?? [], { month, frozenFrom, heldFrom, heldUntil }, (planId: string) => {
    if (legacyValue == null || client.membership_plan_id !== planId) return null;
    return { applies: true, value: legacyValue, month: client.session_count_override_month ?? null };
  });
  return result.plans;
}

/// Starts a freeze now: pauses every subscription, holds this month's
/// unused sessions, and marks the client frozen.
export async function startFreeze(admin: Admin, stripe: Stripe, client: Row, from: string, to: string): Promise<void> {
  const ids = await clientSubscriptionIds(stripe, client);
  const stripeDay = ids.length > 0 ? await pauseSubscriptions(stripe, ids, to) : null;
  const anchorDay = client.billing_anchor_day ?? stripeDay;
  const heldUntil = nextBillingOnOrAfter(to, anchorDay) ?? to;
  const plans = await holdsFor(admin, client, from, to, heldUntil);
  const { error } = await admin.from("clients").update({
    membership_paused: true,
    membership_paused_at: from,
    membership_freeze_ends_at: to,
    plans,
  }).eq("profile_id", client.profile_id);
  if (error) throw new Error("Couldn't save the freeze.");
}

/// Books a freeze that starts on a later day. Nothing is paused and
/// booking stays open until then. apply-due-requests starts it on the day.
export async function scheduleFreeze(admin: Admin, client: Row, from: string, to: string): Promise<void> {
  const { error } = await admin.from("clients").update({
    membership_paused: false,
    membership_paused_at: from,
    membership_freeze_ends_at: to,
  }).eq("profile_id", client.profile_id);
  if (error) throw new Error("Couldn't save the scheduled freeze.");
}

/// Ends a freeze on [endDay] (today for an early unfreeze, the planned end
/// day otherwise). Resumes every subscription when [resumeStripe] is set,
/// moves the held sessions to start on [endDay], and banks the frozen days.
/// A freeze that had not started yet is just cancelled.
export async function endFreeze(
  admin: Admin,
  stripe: Stripe | null,
  client: Row,
  endDay: string,
  opts: { resumeStripe: boolean },
): Promise<{ resumeFailures: number; cancelledScheduled: boolean }> {
  if (!client.membership_paused) {
    const cleared = clearFreezeHolds(client.plans).plans;
    const { error } = await admin.from("clients").update({
      membership_paused_at: null,
      membership_freeze_ends_at: null,
      plans: cleared,
    }).eq("profile_id", client.profile_id);
    if (error) throw new Error("Couldn't cancel the scheduled freeze.");
    return { resumeFailures: 0, cancelledScheduled: true };
  }

  let resumeFailures = 0;
  if (stripe && opts.resumeStripe) {
    const ids = await clientSubscriptionIds(stripe, client);
    resumeFailures = await resumeSubscriptions(stripe, ids);
  }

  const anchorDay = client.billing_anchor_day ?? await stripeAnchorDay(stripe, client);
  const heldUntil = nextBillingOnOrAfter(endDay, anchorDay) ?? endDay;
  const plans = moveFreezeHolds(client.plans, endDay, heldUntil).plans;
  const banked = (client.membership_paused_days || 0) + daysBetween(client.membership_paused_at, endDay);

  const { error } = await admin.from("clients").update({
    membership_paused: false,
    membership_paused_at: null,
    membership_freeze_ends_at: null,
    membership_paused_days: banked,
    plans,
  }).eq("profile_id", client.profile_id);
  if (error) throw new Error("Couldn't end the freeze.");
  return { resumeFailures, cancelledScheduled: false };
}

export { pacificToday };
