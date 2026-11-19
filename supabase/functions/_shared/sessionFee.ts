// Charges a cancel fee or a no-show fee and tells the client.
// The amount comes from cancel_fee_for / attendance_fee_for in the database.
// A cancel never changes how many sessions the client has left.
import { notifyProfile } from "./requestNotify.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";

// deno-lint-ignore no-explicit-any
type Admin = any;

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function collectSessionFee(
  admin: Admin,
  bookingId: string,
  mode: "cancel" | "attendance",
  skipNotice: boolean,
): Promise<Record<string, unknown>> {
  const rpc = mode === "cancel" ? "cancel_fee_for" : "attendance_fee_for";
  const { data: fee, error: feeErr } = await admin.rpc(rpc, { p_booking: bookingId });
  if (feeErr) throw new Error(feeErr.message);
  const cents = Number(fee?.cents ?? 0);
  const kind = String(fee?.kind ?? "free");
  if (!Number.isFinite(cents) || cents <= 0) {
    return { charged: false, feeCents: 0, kind, returnsSession: fee?.returnsSession !== false };
  }

  const { data: existing } = await admin
    .from("charges")
    .select("id")
    .eq("booking_id", bookingId)
    .in("type", ["late", "noshow"])
    .limit(1);
  if (Array.isArray(existing) && existing.length > 0) {
    return { charged: false, alreadyCharged: true, feeCents: cents, kind };
  }

  const { data: booking } = await admin
    .from("bookings")
    .select("client_id, trainer_id, date, slot_min")
    .eq("id", bookingId)
    .maybeSingle();
  const clientId = String(booking?.client_id ?? fee?.clientId ?? "");
  if (!clientId) throw new Error("That booking has no client.");

  const { data: profile } = await admin.from("profiles").select("name").eq("id", clientId).maybeSingle();
  const description = kind === "noshow"
    ? "No-show fee"
    : kind === "close"
      ? "Short-notice cancellation fee"
      : "Late cancellation fee";
  const chargeType = kind === "late" ? "late" : "noshow";

  let charged = false;
  let paymentIntentId: string | null = null;
  let paymentMethodId: string | null = null;
  const { data: clientRow } = await admin
    .from("clients")
    .select("stripe_customer_id, balance_cents")
    .eq("profile_id", clientId)
    .maybeSingle();
  const customerId = clientRow?.stripe_customer_id as string | undefined;
  if (customerId && Deno.env.get("STRIPE_SECRET_KEY")) {
    try {
      const methods = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
      const pm = methods.data[0]?.id;
      if (pm) {
        paymentMethodId = pm;
        const intent = await stripe.paymentIntents.create({
          amount: cents,
          currency: "usd",
          customer: customerId,
          payment_method: pm,
          off_session: true,
          confirm: true,
          description,
          metadata: { booking_id: bookingId, fee_kind: kind },
        });
        paymentIntentId = intent.id;
        charged = intent.status === "succeeded";
        if (!charged) await cancelOpenIntent(intent.id);
      }
    } catch (e) {
      const err = e as { payment_intent?: { id?: string }; message?: string };
      paymentIntentId = err.payment_intent?.id ?? paymentIntentId;
      if (paymentIntentId) await cancelOpenIntent(paymentIntentId);
      console.error("session fee card charge failed:", e instanceof Error ? e.message : String(e));
      charged = false;
    }
  }

  const { error: insertErr } = await admin.from("charges").insert({
    client_id: clientId,
    client_name: profile?.name ?? "",
    type: chargeType,
    date: new Date().toISOString().slice(0, 10),
    at: new Date().toISOString(),
    amount: cents / 100,
    category: "fee",
    description,
    trainer_id: booking?.trainer_id ?? null,
    booking_id: bookingId,
  });
  if (insertErr && !String(insertErr.message).includes("charges_one_fee_per_booking")) {
    throw new Error(insertErr.message);
  }
  if (insertErr) {
    return { charged: false, alreadyCharged: true, feeCents: cents, kind };
  }

  let balanceRecorded = false;
  let balanceCents = Number(clientRow?.balance_cents ?? 0);
  if (!charged) {
    const ledgerType = kind === "close" ? "close" : kind === "noshow" ? "noshow" : "late";
    const { data: recorded, error: recordErr } = await admin.rpc("record_unpaid_fee", {
      p_client: clientId,
      p_type: ledgerType,
      p_amount_cents: cents,
      p_booking: bookingId,
      p_created_by: booking?.trainer_id ?? null,
      p_stripe_payment_intent: paymentIntentId,
      p_stripe_payment_method: paymentMethodId,
    });
    if (recordErr) throw new Error(recordErr.message);
    balanceRecorded = recorded?.alreadyRecorded !== true;
    balanceCents = Number(recorded?.balanceCents ?? balanceCents - cents);
  }

  const amount = dollars(cents);
  const returns = fee?.returnsSession !== false && kind !== "noshow";
  const owed = dollars(Math.abs(balanceCents));
  if (!charged && balanceRecorded) {
    const body = `You have an outstanding balance of ${owed}. Please pay your balance to book sessions.`;
    await notifyProfile(admin, clientId, "Outstanding balance", body, false);
  } else if (!skipNotice && charged) {
    const body = returns
      ? `A ${amount} fee was charged. Your session is back on your plan.`
      : `A ${amount} no-show fee was charged. This session was used.`;
    await notifyProfile(admin, clientId, "Fee charged", body, false);
  }

  return {
    charged,
    balanceRecorded: !charged,
    balanceCents,
    feeCents: cents,
    kind,
    returnsSession: returns,
    alreadyRecorded: !charged && !balanceRecorded,
  };
}

async function cancelOpenIntent(id: string) {
  try {
    await stripe.paymentIntents.cancel(id);
  } catch (_) {
    // Already canceled or already finished. The fee still goes on the balance.
  }
}
