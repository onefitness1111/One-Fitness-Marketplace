// A coach or owner booking a client who has no membership or package.
//
//   mode "charge" - take the single-session price from the client's saved card,
//                   then book. If the card fails nothing is booked.
//   mode "free"   - book it as a free (comped) single session.
//
// Either way the client must have a card on file, so a late cancellation or
// no-show fee can still be collected. Price and eligibility come from settings
// and the database here, not from the app.
//
// Deploy with the login check left on:
//   supabase functions deploy staff-single-session
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCoachPermission } from "../_shared/coachPermissions.ts";
import { bookCredit, notifyFilledRefund, recordPurchase, sessionTypeLabel, settleIncludedBalance, singleSessionConfig } from "../_shared/singleSession.ts";
import {
  FREE_ADD_LIMIT_MESSAGE,
  coachFreeAddBlocked,
  filledSessionRefundNotice,
  pacificWeekRange,
  singleSessionTotal,
} from "../_shared/singleSessionRules.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const b = await req.json().catch(() => ({})) as Record<string, string | number>;
    const { clientId, mode, sessionType, trainerId, date, slot, discipline, locationName } = b;
    if (!clientId || !sessionType || !trainerId || !date || slot === undefined) throw new Error("Missing session details.");
    if (mode !== "charge" && mode !== "free") throw new Error("Choose charge or free.");

    const authed = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");
    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (caller?.role !== "owner" && caller?.role !== "coach") throw new Error("Only a coach or the owner can do this.");
    // Putting a session on another coach's calendar is one switch; charging the card for it is another.
    if (String(trainerId) !== user.id) await requireCoachPermission(admin, user.id, caller.role, "manage_other_schedules");
    if (mode === "charge") await requireCoachPermission(admin, user.id, caller.role, "charge_fees");

    // Amount and customer id only. Phone and billing address are not read.
    const { data: clientRow } = await admin.from("clients").select("stripe_customer_id, balance_cents").eq("profile_id", clientId).maybeSingle();
    if (mode === "free") {
      const { data: balRows, error: balErr } = await admin.rpc("check_booking_balance", {
        p_client: clientId,
        p_target: "booking",
        p_actor_id: user.id,
        p_actor_role: caller.role,
      });
      if (balErr) throw new Error(balErr.message);
      const gate = Array.isArray(balRows) ? balRows[0] : balRows;
      if (gate && !gate.allowed) {
        return json({ status: "error", code: gate.code, message: gate.message });
      }
    }

    if (mode === "free" && coachFreeAddBlocked({ role: caller.role, usedThisWeek: await freeAddsThisWeek(admin, user.id) })) {
      return json({ status: "error", code: "FREE_ADD_LIMIT", message: FREE_ADD_LIMIT_MESSAGE });
    }

    // A card on the client's profile is required either way.
    const customerId = clientRow?.stripe_customer_id as string | null;
    let cardId: string | null = null;
    if (customerId) {
      const methods = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
      cardId = methods.data[0]?.id ?? null;
    }
    if (!cardId) {
      return json({ status: "error", code: "NO_CARD", message: "This client has no card on their profile. Ask them to add one before booking without a plan." });
    }

    const slotReq = {
      trainerId: String(trainerId),
      date: String(date),
      slot: Number(slot),
      sessionType: String(sessionType),
      discipline: String(discipline ?? ""),
      locationName: String(locationName ?? ""),
    };

    let creditId: string;
    let chargedCents = 0;
    let balanceCents = 0;
    let paymentIntentId: string | null = null;
    let paymentMethodId: string | null = null;
    if (mode === "charge") {
      const cfg = await singleSessionConfig(admin, String(sessionType));
      if (!cfg.allowed) throw new Error("Single sessions are turned off for this session type.");
      const bill = singleSessionTotal(cfg.priceCents, clientRow?.balance_cents ?? 0);
      balanceCents = bill.balanceCents;
      chargedCents = bill.totalCents;
      const intent = await stripe.paymentIntents.create({
        amount: bill.totalCents,
        currency: "usd",
        customer: customerId!,
        payment_method: cardId,
        off_session: true,
        confirm: true,
        description: `Single Session — ${sessionTypeLabel(String(sessionType))}`,
        // "_staff": settled right here, so the webhook must not fulfil it again.
        metadata: {
          kind: "single_session_staff",
          profile_id: String(clientId),
          session_type: String(sessionType),
          unit_price_cents: String(bill.sessionCents),
          balance_cents: String(bill.balanceCents),
        },
      });
      if (intent.status !== "succeeded") throw new Error(`The card payment didn't go through (${intent.status}).`);
      paymentIntentId = intent.id;
      paymentMethodId = cardId;
      const { data: credit, error } = await admin.from("single_session_credits").insert({
        client_id: clientId,
        session_type: sessionType,
        price_cents: bill.sessionCents,
        currency: "usd",
        source: "staff_charge",
        stripe_payment_intent_id: intent.id,
        created_by: user.id,
      }).select("id").single();
      if (error) throw error;
      creditId = credit.id as string;
    } else {
      const { data: credit, error } = await admin.from("single_session_credits").insert({
        client_id: clientId,
        session_type: sessionType,
        price_cents: 0,
        currency: "usd",
        source: "staff_free",
        created_by: user.id,
      }).select("id").single();
      if (error) throw error;
      creditId = credit.id as string;
      await recordPurchase(admin, {
        clientId: String(clientId), priceCents: 0, sessionType: String(sessionType),
        paymentIntentId: null, trainerId: slotReq.trainerId, slot: slotReq.slot,
        description: `Single Session — ${sessionTypeLabel(String(sessionType))} (free, by staff)`,
      });
    }

    const res = await bookCredit({
      admin, stripe, creditId, slot: slotReq, chargedCents: chargedCents || undefined,
    });
    if (res.status === "full" && res.refunded && mode === "charge") {
      const { data: profile } = await admin.from("profiles").select("name").eq("id", clientId).maybeSingle();
      const clientName = String(profile?.name ?? "").trim() || "This client";
      const clientBody = filledSessionRefundNotice({ chargedCents, balanceCents });
      const staffBody = filledSessionRefundNotice({ chargedCents, balanceCents, clientName });
      await notifyFilledRefund(admin, {
        clientId: String(clientId),
        body: clientBody,
        creditId,
        staffId: user.id,
        staffBody,
      });
      return json({ ...res, message: staffBody });
    }
    if (res.status === "booked") {
      if (mode === "charge" && paymentIntentId) {
        await recordPurchase(admin, {
          clientId: String(clientId), priceCents: chargedCents - balanceCents, sessionType: String(sessionType),
          paymentIntentId, trainerId: slotReq.trainerId, slot: slotReq.slot,
          description: `Single Session — ${sessionTypeLabel(String(sessionType))} (charged by staff)`,
        });
        if (balanceCents > 0) {
          await settleIncludedBalance(admin, {
            clientId: String(clientId),
            balanceCents,
            paymentIntentId,
            paymentMethodId,
          });
        }
      }

    }
    return json(res);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("staff-single-session failed:", message);
    return json({ status: "error", message }, 400);
  }
});

// Booked free adds this Pacific week. Matches the database count: a credit
// that never became a booking does not use the weekly one.
async function freeAddsThisWeek(admin: ReturnType<typeof createClient>, coachId: string): Promise<number> {
  const week = pacificWeekRange();
  const { data, error } = await admin
    .from("single_session_credits")
    .select("id")
    .eq("source", "staff_free")
    .eq("created_by", coachId)
    .gte("purchased_at", week.start)
    .lt("purchased_at", week.end);
  if (error) throw new Error(error.message);
  const ids = (data ?? []).map((row: { id: string }) => `single:${row.id}`);
  if (ids.length === 0) return 0;
  const { count, error: bookErr } = await admin
    .from("bookings")
    .select("id", { count: "exact", head: true })
    .in("plan_id", ids);
  if (bookErr) throw new Error(bookErr.message);
  return count ?? 0;
}
