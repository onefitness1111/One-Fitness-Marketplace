// Notifications spec — the time-based triggers that fire on a schedule
// rather than a user action: 4 EMAIL ones (Habit reminder, Challenge
// reminder, Card expiration reminder, Monthly progress review reminder)
// plus 3 PUSH ones layered on top of the same run (Habit reminder,
// Challenge reminder, and Appointment reminder 24h before — no email
// equivalent on the spec). Clients who opted in to texts also get the
// appointment, challenge, card-expiry and monthly-review ones by SMS. Nothing else in this
// codebase runs on a schedule, so this is invoked once daily by a pg_cron
// job (see supabase/CRON_SETUP.md) via pg_net's net.http_post — there's no
// user session behind that call, so this is deployed with --no-verify-jwt
// and instead checks its own shared secret (x-cron-secret header vs.
// CRON_SECRET) so it can't be triggered/abused by anyone who just knows
// the URL.
//
// Cadence, chosen to need zero new "did we already send this" tracking
// table — each reminder's own natural condition already prevents re-sends:
//   - Habit: daily, but only to a client who hasn't logged habits yet today.
//   - Challenge: only runs on Mondays (once/week) for clients in an
//     active, not-yet-ended challenge.
//   - Card expiration / Monthly review: only run on the 1st of the month.
//   - Appointment reminder: daily, only for bookings on tomorrow's date —
//     this cron runs once/day at a fixed time (see CRON_SETUP.md), so
//     "24h before" is approximated as "the day before", not a precise
//     24-hour countdown per booking; a booking made same-day for tomorrow
//     only gets one reminder, never a duplicate, since it's keyed off the
//     booking's date, not a timer.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { sendEmail } from "../_shared/sendEmail.ts";
import { sendPush } from "../_shared/sendPush.ts";
import { sendSms } from "../_shared/sendSms.ts";
import { offerSlot } from "../_shared/waitlistOffers.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const now = new Date();
    const todayIso = now.toISOString().slice(0, 10);
    const tomorrowIso = new Date(now.getTime() + 86400000).toISOString().slice(0, 10);
    const isMonday = now.getUTCDay() === 1;
    const isFirstOfMonth = now.getUTCDate() === 1;

    // Waitlist offers nobody answered. Without this a client who ignores the
    // notification holds the slot until its window lapses and then nothing
    // happens — the queue silently stalls and the session goes unfilled.
    // Passing it down the line here is what keeps it moving.
    try {
      const nowIso = now.toISOString();
      const { data: stale } = await admin.from("waitlist")
        .select("id, trainer_id, date, slot")
        .eq("status", "offered")
        .lt("offer_expires_at", nowIso);
      for (const entry of stale ?? []) {
        await admin.from("waitlist")
          .update({ status: "declined", declined_at: nowIso })
          .eq("id", entry.id);
        await offerSlot(entry.trainer_id, entry.date, Number(entry.slot));
        console.log(`send-scheduled-reminders: waitlist offer ${entry.id} expired, passed on`);
      }
    } catch (e) {
      console.error("send-scheduled-reminders: waitlist sweep failed:", e instanceof Error ? e.message : String(e));
    }

    async function pushToProfile(profileId: string, title: string, body: string) {
      const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
      await sendPush((rows || []).map((r) => r.token as string), title, body);
    }

    const { data: clients } = await admin.from("clients").select("profile_id, stripe_customer_id, sms_opt_in");
    const { data: profiles } = await admin.from("profiles").select("id, name, email, phone, sms_opted_out");
    const profileById = new Map((profiles || []).map((p) => [p.id, p]));
    const smsOptedIn = new Set((clients || []).filter((c) => c.sms_opt_in === true).map((c) => c.profile_id));

    // Texts only clients who ticked the SMS box (see _shared/notifySms.ts);
    // the habit reminder is daily, so it stays push/email only.
    async function textClient(profileId: string, text: string) {
      if (!smsOptedIn.has(profileId)) return;
      // STOP is final even if sms_opt_in was somehow left on.
      if (profileById.get(profileId)?.sms_opted_out === true) return;
      const phone = String(profileById.get(profileId)?.phone ?? "").trim();
      if (phone) await sendSms(phone, `ONE Fitness: ${text}`);
    }

    let activeChallenges: any[] | null = null;
    if (isMonday) {
      const { data } = await admin.from("challenges").select("id, name, participants, end_date").gte("end_date", todayIso);
      activeChallenges = data;
    }

    // ---- Appointment reminder 24h before (push-only, every day) ----
    // No `status` column on bookings — a cancelled booking is hard-deleted
    // (see SupabaseService.deleteBooking), so any row that still exists is
    // inherently active; `cancelled_at` is checked defensively in case
    // anything ever sets it instead of deleting the row.
    const { data: tomorrowBookings } = await admin.from("bookings")
      .select("client_id, trainer_id, slot_min, session_type")
      .eq("date", tomorrowIso)
      .is("cancelled_at", null);
    let appointmentReminders = 0;
    for (const b of tomorrowBookings || []) {
      const hour = Math.floor((b.slot_min ?? 0) / 60);
      const minute = (b.slot_min ?? 0) % 60;
      const time12 = `${hour % 12 === 0 ? 12 : hour % 12}:${minute.toString().padStart(2, "0")} ${hour < 12 ? "AM" : "PM"}`;
      try {
        await pushToProfile(b.client_id, "Appointment tomorrow", `You have a session tomorrow at ${time12}.`);
        await textClient(b.client_id, `Reminder: you have a session tomorrow at ${time12}.`);
        appointmentReminders++;
      } catch (e) {
        console.error(`send-scheduled-reminders: appointment reminder failed for ${b.client_id}:`, e instanceof Error ? e.message : String(e));
      }
    }

    let sent = { habit: 0, challenge: 0, cardExpiring: 0, monthlyReview: 0 };

    for (const c of clients || []) {
      const profile = profileById.get(c.profile_id);
      if (!profile) continue;

      // ---- Habit reminder (daily, only if not already logged today) ----
      const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", c.profile_id).maybeSingle();
      const record = recordRow?.data || {};
      const hasHabits = ((record.habits as string[] | undefined)?.length ?? 0) > 0 || ((record.customHabits as any[] | undefined)?.length ?? 0) > 0;
      const loggedToday = !!(record.habitLogByDate || {})[todayIso];
      if (hasHabits && !loggedToday) {
        if (profile.email) await sendEmail(profile.email, "Don't forget your habits today", `Hi ${profile.name || "there"},\n\nJust a reminder to log today's habits in the ONE Fitness app.\n\n— ONE Fitness`);
        await pushToProfile(c.profile_id, "Habit reminder", "Don't forget to log today's habits.");
        sent.habit++;
      }

      // ---- Challenge reminder (Mondays, active challenges only) ----
      if (isMonday && activeChallenges) {
        for (const ch of activeChallenges) {
          const participants: string[] = ch.participants || [];
          if (!participants.includes(c.profile_id)) continue;
          if (profile.email) {
            await sendEmail(
              profile.email,
              `Reminder: "${ch.name}" is still going`,
              `Hi ${profile.name || "there"},\n\nJust a reminder you're enrolled in the "${ch.name}" challenge — keep up your progress! It runs through ${ch.end_date}.\n\n— ONE Fitness`,
            );
          }
          await pushToProfile(c.profile_id, "Challenge reminder", `"${ch.name}" is still going — keep it up!`);
          await textClient(c.profile_id, `"${ch.name}" is still going. Keep it up!`);
          sent.challenge++;
        }
      }

      if (isFirstOfMonth) {
        // ---- Card expiration reminder (card expires next calendar month) ----
        if (c.stripe_customer_id && profile.email) {
          try {
            const pms = await stripe.paymentMethods.list({ customer: c.stripe_customer_id, type: "card" });
            for (const pm of pms.data) {
              if (!pm.card) continue;
              const monthsUntilExpiry = (pm.card.exp_year - now.getUTCFullYear()) * 12 + (pm.card.exp_month - 1 - now.getUTCMonth());
              if (monthsUntilExpiry === 1) {
                await sendEmail(
                  profile.email,
                  "Your card on file is expiring soon",
                  `Hi ${profile.name || "there"},\n\nThe card ending in ${pm.card.last4} on your ONE Fitness account expires ${pm.card.exp_month}/${pm.card.exp_year}. Please update your payment method in the app to avoid any interruption.\n\n— ONE Fitness`,
                );
                await textClient(c.profile_id, `The card ending in ${pm.card.last4} on your account expires ${pm.card.exp_month}/${pm.card.exp_year}. Please update it in the app.`);
                sent.cardExpiring++;
              }
            }
          } catch (e) {
            console.error(`send-scheduled-reminders: card lookup failed for ${c.profile_id}:`, e instanceof Error ? e.message : String(e));
          }
        }

        // ---- Monthly progress review reminder (client only: clients are not
        // assigned to one coach, so there is no "their coach" to email) ----
        if (profile.email) {
          await sendEmail(
            profile.email,
            "Time for your monthly progress review",
            `Hi ${profile.name || "there"},\n\nIt's a new month — a great time to check in with your coach on your progress and set goals for the weeks ahead.\n\n— ONE Fitness`,
          );
          await textClient(c.profile_id, "It's a new month, a great time to check in with your coach on your progress.");
          sent.monthlyReview++;
        }
      }
    }

    console.log(`send-scheduled-reminders: habit=${sent.habit} challenge=${sent.challenge} cardExpiring=${sent.cardExpiring} monthlyReview=${sent.monthlyReview} appointmentReminders=${appointmentReminders}`);
    return new Response(JSON.stringify({ ok: true, sent: { ...sent, appointmentReminders } }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-scheduled-reminders failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
