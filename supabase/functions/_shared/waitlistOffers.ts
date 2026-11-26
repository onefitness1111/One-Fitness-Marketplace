// Waitlist offer logic shared by offer-waitlist-slot (the HTTP entry),
// respond-waitlist-offer and waitlist-sweep. Lives here, not in one of the
// function directories, because importing a function's index.ts also runs
// its top-level serve() — which silently replaced the importing function's
// own handler.
//
// Offers cascade rather than queue strictly: each person has four hours to
// answer, and every two hours the next person in line is offered the same
// slot as well. The first to accept gets it; the others are told it's gone.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendPush } from "./sendPush.ts";
import { sendEmail } from "./sendEmail.ts";
import { sendSms } from "./sendSms.ts";

/// How long each person has to answer.
export const OFFER_WINDOW_MINUTES = 240;
/// How long after the latest offer the next person is offered too.
export const CASCADE_INTERVAL_MINUTES = 120;

const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

function fmtSlot(minutes: number): string {
  const h24 = Math.floor(minutes / 60);
  const m = minutes % 60;
  const h = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${h}:${String(m).padStart(2, "0")} ${h24 < 12 ? "AM" : "PM"}`;
}

async function notifyClient(clientId: string, title: string, body: string, emailBody?: string) {
  const { data: tokens } = await admin.from("device_tokens").select("token").eq("profile_id", clientId);
  await sendPush((tokens || []).map((t: { token: string }) => t.token), title, body);
  const { data: profile } = await admin.from("profiles").select("email, name, phone").eq("id", clientId).maybeSingle();
  // Respect the client's own SMS preference (Profile Settings ->
  // Notification Preferences), not just whether we happen to have a number.
  const { data: prefs } = await admin.from("clients").select("sms_opt_in").eq("profile_id", clientId).maybeSingle();
  const phone = String(profile?.phone ?? "").trim();
  if (phone && prefs?.sms_opt_in !== false) await sendSms(phone, `ONE Fitness: ${body}`);
  if (profile?.email) await sendEmail(profile.email, title, emailBody ?? `Hi ${profile.name ?? ""},\n\n${body}\n\n— ONE Fitness`);
}

/// Expires stale offers for one slot, then — if it's time — offers the next
/// waiting person. Exported so the cancel path, the decline path and the
/// sweep all drive the same logic. Returns the entry id offered, or null.
export async function offerSlot(trainerId: string, date: string, slot: number): Promise<string | null> {
  const now = Date.now();
  const nowIso = new Date(now).toISOString();

  // 1. Anyone whose window has closed is marked expired and told so.
  const { data: stale } = await admin.from("waitlist")
    .select("id, client_id").eq("trainer_id", trainerId).eq("date", date).eq("slot", slot)
    .eq("status", "offered").lt("offer_expires_at", nowIso);
  for (const s of stale ?? []) {
    await admin.from("waitlist").update({ status: "expired" }).eq("id", s.id);
    await notifyClient(
      s.client_id as string,
      "Waitlist offer expired",
      `Your ${OFFER_WINDOW_MINUTES / 60}-hour window to claim ${date} at ${fmtSlot(slot)} has passed. It's been offered to the next person waiting.`,
    );
  }

  // 2. Nothing to offer if the slot got filled meanwhile (a coach may have
  //    rebooked it by hand, or an earlier offer was just accepted).
  const { data: taken } = await admin.from("bookings")
    .select("id").eq("trainer_id", trainerId).eq("date", date).eq("slot_min", slot)
    .is("cancelled_at", null).limit(1);
  if (taken && taken.length > 0) return null;

  // 3. The cascade: the next person is offered when nobody holds a live
  //    offer, or the newest live offer is at least the interval old.
  const { data: live } = await admin.from("waitlist")
    .select("offered_at").eq("trainer_id", trainerId).eq("date", date).eq("slot", slot)
    .eq("status", "offered").gt("offer_expires_at", nowIso)
    .order("offered_at", { ascending: false }).limit(1);
  const newest = live?.[0]?.offered_at ? new Date(live[0].offered_at as string).getTime() : null;
  if (newest !== null && now - newest < CASCADE_INTERVAL_MINUTES * 60000) return null;

  const { data: queue } = await admin.from("waitlist")
    .select("*").eq("trainer_id", trainerId).eq("date", date).eq("slot", slot)
    .eq("status", "waiting")
    // position first (the order people joined), created_at as the tiebreak
    // for legacy rows that never got one.
    .order("position", { ascending: true, nullsFirst: false })
    .order("created_at", { ascending: true })
    .limit(1);
  const next = queue?.[0];
  if (!next) return null;

  const expiresAt = new Date(now + OFFER_WINDOW_MINUTES * 60000).toISOString();
  const { error: offerErr } = await admin.from("waitlist")
    .update({ status: "offered", offered_at: nowIso, offer_expires_at: expiresAt })
    .eq("id", next.id);
  if (offerErr) throw offerErr;

  const when = `${date} at ${fmtSlot(Number(next.slot) || 0)}`;
  const title = "A spot just opened up";
  const body = `${when} with ${next.trainer_name || "your coach"} is free. Open the app to claim it — it's held for you for ${OFFER_WINDOW_MINUTES / 60} hours. First to accept gets it.`;
  await notifyClient(
    next.client_id as string,
    title,
    body,
    `Hi ${next.client_name ?? ""},\n\n${body}\n\nIf you don't claim it in time it passes to the next person waiting.\n\n— ONE Fitness`,
  );

  console.log(`offer-waitlist-slot: offered ${trainerId} ${date} ${slot} to ${next.client_id}`);
  return next.id as string;
}

/// Someone claimed the slot: every other live offer for it is closed and
/// those people are told, so nobody keeps trying to accept a slot that's
/// gone.
export async function closeOtherOffers(trainerId: string, date: string, slot: number, winnerEntryId: string) {
  const { data: others } = await admin.from("waitlist")
    .select("id, client_id").eq("trainer_id", trainerId).eq("date", date).eq("slot", slot)
    .eq("status", "offered").neq("id", winnerEntryId);
  for (const o of others ?? []) {
    await admin.from("waitlist").update({ status: "missed" }).eq("id", o.id);
    await notifyClient(
      o.client_id as string,
      "That spot's been taken",
      `Someone else claimed ${date} at ${fmtSlot(slot)} first. You're welcome to join the waitlist for another session.`,
    );
  }
}

