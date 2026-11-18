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
        charged = intent.status === "succeeded";
      }
    } catch (e) {
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

  if (!charged) {
    const current = Number(clientRow?.balance_cents ?? 0);
    await admin.from("clients").update({ balance_cents: current - cents }).eq("profile_id", clientId);
  }

  if (!skipNotice) {
    const amount = dollars(cents);
    const returns = fee?.returnsSession !== false && kind !== "noshow";
    const body = charged
      ? (returns
        ? `A ${amount} fee was charged. Your session is back on your plan.`
        : `A ${amount} no-show fee was charged. This session was used.`)
      : (returns
        ? `We couldn't charge the ${amount} fee, so it's on your balance. Your session is back on your plan.`
        : `We couldn't charge the ${amount} no-show fee, so it's on your balance. This session was used.`);
    await notifyProfile(admin, clientId, charged ? "Fee charged" : "Fee added to your balance", body, true);
  }

  return { charged, feeCents: cents, kind, returnsSession: fee?.returnsSession !== false && kind !== "noshow" };
}
