// Single (one-off) sessions: price lookup, and the one fulfilment path that
// turns "Stripe says it's paid" into a credit and a booking.
//
// Used by the in-app confirmation call AND the Stripe webhook, which can both
// arrive for the same payment — so everything here is idempotent: the credit is
// keyed by the PaymentIntent id (unique index), the booking is made by an
// atomic RPC that locks the credit row, and the refund on a full session uses a
// fixed idempotency key. No double charge, no double booking.
import type Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { coachDisplayName } from "./coachName.ts";
import { sendEmailOrThrow } from "./sendEmail.ts";
import { businessName, loadTemplate, renderEmail } from "./emailTemplates.ts";
import { notifyProfile } from "./requestNotify.ts";
import { filledSessionRefundNotice } from "./singleSessionRules.mjs";

// deno-lint-ignore no-explicit-any
type Admin = any;

export const SESSION_TYPE_LABELS: Record<string, string> = {
  "one-on-one": "One-on-one",
  "semi-private": "Semi-private",
  "large-group": "Large group",
  outdoor: "Outdoor",
};
export function sessionTypeLabel(t: string): string {
  if (SESSION_TYPE_LABELS[t]) return SESSION_TYPE_LABELS[t];
  const s = (t || "").replace(/[-_]+/g, " ").trim();
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : "Session";
}

/// What the owner set for this session type. The ONLY source of price and the
/// Allowed flag — never the request.
export async function singleSessionConfig(
  admin: Admin,
  sessionType: string,
): Promise<{ allowed: boolean; priceCents: number; offered: boolean }> {
  const { data } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
  const d = (data?.data ?? {}) as Record<string, Record<string, unknown>>;
  const cfg = ((d.scheduling?.singleSession ?? {}) as Record<string, { priceCents?: number; allowed?: boolean }>)[sessionType];
  const offeredList = d.services?.offeredSessionTypes;
  const offered = Array.isArray(offeredList) ? (offeredList as string[]).includes(sessionType) : true;
  const priceCents = Math.round(Number(cfg?.priceCents ?? 0));
  return { allowed: cfg?.allowed === true && priceCents > 0, priceCents, offered };
}

export type SlotRequest = {
  trainerId: string;
  date: string; // yyyy-MM-dd
  slot: number; // minutes from midnight
  sessionType: string;
  discipline: string;
  locationName: string;
};

export type FulfilResult =
  | { status: "booked"; bookingId: string; creditId: string }
  | { status: "full"; creditId: string; refunded: boolean; message?: string }
  | { status: "error"; message: string; creditId?: string };

function timeLabel(slotMin: number): string {
  const h24 = Math.floor(slotMin / 60);
  const m = slotMin % 60;
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${h12}:${String(m).padStart(2, "0")} ${h24 >= 12 ? "PM" : "AM"}`;
}
function dateLabel(iso: string): string {
  return new Date(iso + "T12:00:00Z").toLocaleDateString("en-US", {
    weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC",
  });
}
const money = (c: number) => (c % 100 === 0 ? `$${c / 100}` : `$${(c / 100).toFixed(2)}`);

/// Records the purchase (charges row, tagged "Single Session" + type), once.
async function recordPurchase(admin: Admin, opts: {
  clientId: string; priceCents: number; sessionType: string; paymentIntentId: string | null; trainerId: string; slot: number;
  description: string;
}) {
  const { data: profile } = await admin.from("profiles").select("name").eq("id", opts.clientId).maybeSingle();
  const { data: trainer } = await admin.from("profiles").select("name").eq("id", opts.trainerId).maybeSingle();
  const now = new Date();
  await admin.from("charges").insert({
    client_id: opts.clientId,
    client_name: profile?.name ?? "",
    type: "purchase", // so the owner's existing Refund action works on it
    date: now.toISOString().slice(0, 10),
    at: now.toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
    amount: opts.priceCents / 100,
    category: "Single Session",
    description: opts.description,
    plan_name: `Single Session — ${sessionTypeLabel(opts.sessionType)}`,
    trainer_id: opts.trainerId,
    trainer_name: trainer?.name ?? null,
    slot: opts.slot,
    stripe_payment_intent_id: opts.paymentIntentId,
  });
}

async function sendReceipt(admin: Admin, creditId: string, slot: SlotRequest) {
  try {
    const { data: credit } = await admin.from("single_session_credits").select("*").eq("id", creditId).maybeSingle();
    if (!credit || credit.receipt_sent_at || Number(credit.price_cents) <= 0) return;
    const template = await loadTemplate(admin, "single_session_receipt");
    if (!template || !template.enabled) return;
    // Claim first so a retry can't send a second receipt.
    const { data: claimed } = await admin.from("single_session_credits")
      .update({ receipt_sent_at: new Date().toISOString() })
      .eq("id", creditId).is("receipt_sent_at", null).select("id");
    if (!claimed || claimed.length === 0) return;
    const { data: client } = await admin.from("profiles").select("name, email").eq("id", credit.client_id).maybeSingle();
    if (!client?.email) return;
    const { data: coach } = await admin.from("profiles").select("name").eq("id", slot.trainerId).maybeSingle();
    const business = await businessName(admin);
    const { subject, html } = renderEmail({
      template,
      business,
      vars: {
        client_first_name: ((client.name as string) || "there").trim().split(/\s+/)[0],
        business_name: business,
        session_type: sessionTypeLabel(slot.sessionType),
        session_date: dateLabel(slot.date),
        session_time: timeLabel(slot.slot),
        coach_name: coachDisplayName(coach?.name as string),
        session_location: slot.locationName || "See the app for the location",
        amount_paid: money(Number(credit.price_cents)),
        purchase_date: dateLabel(String(credit.purchased_at).slice(0, 10)),
        expires_on: dateLabel(String(credit.expires_at).slice(0, 10)),
      },
    });
    await sendEmailOrThrow(client.email as string, subject, "", html);
  } catch (e) {
    console.error("single session receipt failed:", e instanceof Error ? e.message : String(e));
  }
}

/// Books the credit into the requested slot atomically. If the session filled
/// while the client was paying, the money is refunded (Stripe payments) and the
/// credit voided, so nothing is held on an unpaid-for or unavailable seat.
export async function bookCredit(opts: {
  admin: Admin;
  stripe: Stripe | null;
  creditId: string;
  slot: SlotRequest;
  /// Whole amount taken on the card, when the charge also included a balance.
  /// A failed booking refunds this entire amount. The balance is not touched.
  chargedCents?: number;
}): Promise<FulfilResult> {
  const { admin, stripe, creditId, slot } = opts;
  const { data: res, error } = await admin.rpc("book_single_session", {
    p_credit_id: creditId,
    p_trainer_id: slot.trainerId,
    p_date: slot.date,
    p_slot: slot.slot,
    p_session_type: slot.sessionType,
    p_discipline: slot.discipline,
    p_location_name: slot.locationName,
  });
  if (error) return { status: "error", message: error.message, creditId };
  const r = res as { status: string; booking_id?: string; message?: string };
  if (r.status === "booked" && r.booking_id) {
    await sendReceipt(admin, creditId, slot);
    return { status: "booked", bookingId: r.booking_id, creditId };
  }
  if (r.status === "full") {
    const { data: credit } = await admin.from("single_session_credits").select("*").eq("id", creditId).maybeSingle();
    let refunded = false;
    if (credit?.stripe_payment_intent_id && stripe && credit.status === "active") {
      try {
        await stripe.refunds.create(
          { payment_intent: credit.stripe_payment_intent_id, reason: "requested_by_customer" },
          { idempotencyKey: `single-full-${credit.stripe_payment_intent_id}` },
        );
        refunded = true;
      } catch (e) {
        console.error("single session auto-refund failed:", e instanceof Error ? e.message : String(e));
      }
    }
    if (refunded || !credit?.stripe_payment_intent_id) {
      await admin.from("single_session_credits").update({ status: "refunded" }).eq("id", creditId);
    }
    if (refunded && credit) {
      const now = new Date();
      const refundCents = opts.chargedCents && opts.chargedCents > 0
        ? opts.chargedCents
        : Number(credit.price_cents);
      await admin.from("charges").insert({
        client_id: credit.client_id,
        client_name: "",
        type: "refund",
        date: now.toISOString().slice(0, 10),
        at: now.toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
        amount: -(refundCents / 100),
        category: "Single Session",
        description: "Refunded — the session filled, so the whole charge was returned and the balance was left unchanged",
        plan_name: `Single Session — ${sessionTypeLabel(credit.session_type)}`,
        stripe_payment_intent_id: credit.stripe_payment_intent_id,
      });
    }
    return { status: "full", creditId, refunded };
  }
  return { status: "error", message: r.message ?? "Couldn't book the session.", creditId };
}

/// A succeeded Stripe PaymentIntent -> credit (once) -> booking.
export async function fulfillSingleSessionPayment(opts: {
  admin: Admin;
  stripe: Stripe;
  pi: Stripe.PaymentIntent;
}): Promise<FulfilResult> {
  const { admin, stripe, pi } = opts;
  const meta = (pi.metadata ?? {}) as Record<string, string>;
  if (meta.kind !== "single_session" || !meta.profile_id) return { status: "error", message: "Not a single-session payment." };
  if (pi.status !== "succeeded") return { status: "error", message: "Payment hasn't completed." };

  const slot: SlotRequest = {
    trainerId: meta.trainer_id,
    date: meta.date,
    slot: Number(meta.slot),
    sessionType: meta.session_type,
    discipline: meta.discipline ?? "",
    locationName: meta.location_name ?? "",
  };

  // Credit: one per PaymentIntent. The unique index settles a webhook/confirm race.
  let creditId: string | null = null;
  const { data: existing } = await admin.from("single_session_credits")
    .select("id").eq("stripe_payment_intent_id", pi.id).maybeSingle();
  if (existing) {
    creditId = existing.id as string;
  } else {
    const sessionCents = Math.round(Number(meta.unit_price_cents || pi.amount_received || pi.amount));
    const { data: created, error } = await admin.from("single_session_credits").insert({
      client_id: meta.profile_id,
      session_type: meta.session_type,
      // The session price only. Any outstanding balance on the same charge
      // is settled separately, and only after the seat is booked.
      price_cents: sessionCents,
      currency: pi.currency || "usd",
      source: "purchase",
      stripe_payment_intent_id: pi.id,
    }).select("id").single();
    if (error) {
      const { data: again } = await admin.from("single_session_credits")
        .select("id").eq("stripe_payment_intent_id", pi.id).maybeSingle();
      if (!again) return { status: "error", message: error.message };
      creditId = again.id as string;
    } else {
      creditId = created.id as string;
    }
  }
  const sessionCents = Math.round(Number(meta.unit_price_cents || pi.amount_received || pi.amount));
  const balanceCents = Math.round(Number(meta.balance_cents || 0));
  const chargedCents = pi.amount_received || pi.amount;
  const booked = await bookCredit({ admin, stripe, creditId: creditId!, slot, chargedCents });
  if (booked.status === "full" && booked.refunded) {
    const message = filledSessionRefundNotice({ chargedCents, balanceCents });
    await notifyFilledRefund(admin, {
      clientId: meta.profile_id,
      body: message,
      creditId: creditId!,
    });
    return { ...booked, message };
  }
  if (booked.status === "booked") {
    const { data: sessionCharge } = await admin.from("charges").select("id")
      .eq("stripe_payment_intent_id", pi.id).eq("category", "Single Session").eq("type", "purchase").maybeSingle();
    if (!sessionCharge) await recordPurchase(admin, {
      clientId: meta.profile_id,
      priceCents: sessionCents,
      sessionType: meta.session_type,
      paymentIntentId: pi.id,
      trainerId: slot.trainerId,
      slot: slot.slot,
      description: `Single Session — ${sessionTypeLabel(meta.session_type)}`,
    });
    if (balanceCents > 0) {
      await settleIncludedBalance(admin, {
        clientId: meta.profile_id,
        balanceCents,
        paymentIntentId: pi.id,
        paymentMethodId: typeof pi.payment_method === "string" ? pi.payment_method : pi.payment_method?.id ?? null,
      });
    }
  }
  return booked;
}

/// Push plus an in-app notice. A missing device or a missing notices table
/// must not undo the refund.
export async function notifyFilledRefund(admin: Admin, opts: {
  clientId: string;
  body: string;
  creditId: string;
  staffId?: string | null;
  staffBody?: string | null;
}) {
  await notifyProfile(admin, opts.clientId, "Session filled", opts.body, false);
  await writeRefundNotice(admin, opts.clientId, opts.creditId, opts.body);
  if (opts.staffId && opts.staffId !== opts.clientId && opts.staffBody) {
    await notifyProfile(admin, opts.staffId, "Session filled", opts.staffBody, false);
    await writeRefundNotice(admin, opts.staffId, opts.creditId, opts.staffBody);
  }
}

async function writeRefundNotice(admin: Admin, profileId: string, creditId: string, body: string) {
  try {
    await admin.from("client_notices").insert({
      client_id: profileId,
      kind: "session_refund",
      plan_id: creditId,
      title: "Session filled",
      body,
    });
  } catch (e) {
    console.error("session refund notice failed:", e instanceof Error ? e.message : String(e));
  }
}

/// Marks the unpaid fees paid. Called only after the session is booked.
/// A second confirm for the same payment does not credit the balance again.
export async function settleIncludedBalance(admin: Admin, opts: {
  clientId: string;
  balanceCents: number;
  paymentIntentId: string;
  paymentMethodId: string | null;
}) {
  if (opts.balanceCents <= 0) return;
  const { data: existing } = await admin.from("charges").select("id")
    .eq("stripe_payment_intent_id", opts.paymentIntentId)
    .eq("category", "Balance")
    .maybeSingle();
  if (existing) return;
  const { data: client } = await admin.from("clients").select("balance_cents").eq("profile_id", opts.clientId).maybeSingle();
  if (Number(client?.balance_cents ?? 0) >= 0) return;
  const { error } = await admin.rpc("apply_balance_payment", {
    p_client: opts.clientId,
    p_amount_cents: opts.balanceCents,
    p_payment_intent: opts.paymentIntentId,
    p_payment_method: opts.paymentMethodId,
  });
  if (error) throw new Error(error.message);
  const { data: profile } = await admin.from("profiles").select("name").eq("id", opts.clientId).maybeSingle();
  const now = new Date();
  await admin.from("charges").insert({
    client_id: opts.clientId,
    client_name: profile?.name ?? "",
    type: "purchase",
    date: now.toISOString().slice(0, 10),
    at: now.toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
    amount: opts.balanceCents / 100,
    category: "Balance",
    description: "Outstanding balance payment",
    plan_name: "Outstanding balance",
    stripe_payment_intent_id: opts.paymentIntentId,
    payment_method_id: opts.paymentMethodId,
  });
}

export { recordPurchase };
