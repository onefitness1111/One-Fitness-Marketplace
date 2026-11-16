// The owner approves or denies a coach request, then the change is carried
// out. A freeze is only scheduled: it starts after 48 hours (apply-due-requests).
// Proposed. Not deployed until you deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

// deno-lint-ignore no-explicit-any
type Admin = any;

function kindLine(kind: string, approved: boolean): string {
  const verb = approved ? "approved" : "denied";
  switch (kind) {
    case "freeze_membership":
      return approved
        ? "Your freeze request was approved. It starts 48 hours after approval, or on the from-date if that is later."
        : "Your freeze request was denied.";
    case "unfreeze_membership":
      return `Your request to end a freeze was ${verb}.`;
    case "restrict_client":
      return `Your request to restrict a client was ${verb}.`;
    case "lift_restriction":
      return `Your request to lift a restriction was ${verb}.`;
    case "extra_free_session":
      return `Your request for an extra free session was ${verb}.`;
    case "adjust_balance":
      return `Your request to change a balance was ${verb}.`;
    case "delete_client":
      return `Your request to delete a client was ${verb}.`;
    default:
      return `Your request was ${verb}.`;
  }
}

function clientLine(kind: string, approved: boolean, extra: string): string | null {
  if (!approved) return null;
  switch (kind) {
    case "freeze_membership":
      return `Your membership freeze was approved. It starts ${extra}. You will be told again when it begins.`;
    case "unfreeze_membership":
      return "Your membership freeze has ended.";
    case "restrict_client":
      return "Your account is restricted from booking new sessions. Talk to ONE Fitness if you have a question.";
    case "lift_restriction":
      return "The restriction on booking has been lifted. You can book again.";
    case "extra_free_session":
      return `You were added to a session${extra}.`;
    case "adjust_balance":
      return "The balance on your account was updated.";
    case "delete_client":
      return null;
    default:
      return null;
  }
}

async function bookApprovedFreeSession(admin: Admin, ownerId: string, payload: Record<string, unknown>) {
  const clientId = String(payload.clientId ?? payload.client_id ?? "");
  const trainerId = String(payload.trainerId ?? "");
  const date = String(payload.date ?? "");
  const slot = Number(payload.slot);
  const sessionType = String(payload.sessionType ?? "");
  const discipline = String(payload.discipline ?? "");
  const locationName = String(payload.locationName ?? "");
  if (!clientId || !trainerId || !date || Number.isNaN(slot) || !sessionType) {
    throw new Error("The free-session request is missing the session.");
  }

  const { data: clientRow } = await admin.from("clients").select("stripe_customer_id").eq("profile_id", clientId).maybeSingle();
  const customerId = clientRow?.stripe_customer_id as string | null;
  let cardId: string | null = null;
  if (customerId) {
    const methods = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
    cardId = methods.data[0]?.id ?? null;
  }
  if (!cardId) throw new Error("This client has no card on their profile, so the free session can't be booked yet.");

  const { data: credit, error } = await admin.from("single_session_credits").insert({
    client_id: clientId,
    session_type: sessionType,
    price_cents: 0,
    currency: "usd",
    source: "staff_free",
    created_by: ownerId,
  }).select("id").single();
  if (error) throw error;

  const { data: booked, error: bookErr } = await admin.rpc("book_single_session", {
    p_credit_id: credit.id,
    p_trainer_id: trainerId,
    p_date: date,
    p_slot: slot,
    p_session_type: sessionType,
    p_discipline: discipline,
    p_location_name: locationName,
  });
  if (bookErr) throw bookErr;
  if (booked?.status !== "booked") {
    throw new Error(booked?.message ?? "Couldn't book that free session.");
  }
  return booked.booking_id as string;
}

async function callAsOwner(req: Request, name: string, body: unknown) {
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/${name}`, {
    method: "POST",
    headers: {
      Authorization: req.headers.get("Authorization") ?? "",
      apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    let message = text;
    try {
      message = JSON.parse(text).error ?? text;
    } catch { /* keep text */ }
    throw new Error(message || `Couldn't finish ${name}.`);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const body = await req.json();
    const approve = body.approve === true;
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const { data, error } = await userClient.rpc("decide_coach_request", {
      p_id: body.id,
      p_approve: approve,
      p_note: body.note ?? "",
    });
    if (error) throw new Error(error.message);

    const kind = String(data.kind);
    const clientId = data.clientId as string | null;
    const coachId = String(data.coachId);
    const payload = (data.payload ?? {}) as Record<string, unknown>;

    if (approve && kind === "extra_free_session") {
      const bookingId = await bookApprovedFreeSession(admin, user.id, { ...payload, clientId });
      await admin.rpc("mark_request_applied", { p_id: body.id, p_booking: bookingId });
    }
    if (approve && kind === "delete_client" && clientId) {
      await callAsOwner(req, "delete-client-account", { clientId });
      await admin.rpc("mark_request_applied", { p_id: body.id, p_booking: null });
    }
    if (approve && kind === "unfreeze_membership" && clientId) {
      await callAsOwner(req, "unfreeze-membership", { clientId });
    }

    const when = data.effectiveAt ? String(data.effectiveAt).slice(0, 10) : "after the 48-hour wait";
    await notifyProfile(admin, coachId, approve ? "Request approved" : "Request denied", kindLine(kind, approve), false);
    if (clientId) {
      const line = clientLine(kind, approve, kind === "freeze_membership" ? when : "");
      if (line) await notifyProfile(admin, clientId, "ONE Fitness", line, true);
    }

    return json({ ok: true, decision: data });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("decide-coach-request failed:", message);
    return json({ error: message }, 400);
  }
});
