// Scheduled reminders. pg_cron calls this every hour on the hour (job
// "send-scheduled-reminders-hourly"); _shared/reminderRules.mjs decides
// what is due, in Pacific time. Coach Chris's rules (Nov 27, 2026):
//
// - Session reminder about 24 hours before each session (push, plus a text
//   for clients who opted in). One per booking, recorded in
//   scheduled_notices. Replaces the old 5am "tomorrow" batch.
// - Habit reminder at 7pm Pacific, only to clients with habits who have not
//   logged that day (push and email; no text).
// - Challenges, participants only: when the challenge is created or they
//   are added, Monday 8am, and 8am two days before it closes (push, email,
//   text if opted in).
// - 1st of the month at 9am: card-expiring warning and monthly review.
// - Quiet hours 9pm-8am: nothing is sent. Texts queued during quiet hours
//   by any function (sms_outbox) go out on the first run after 8am.
//
// Also passes stale waitlist offers down the line, as before.
//
// Deployed --no-verify-jwt. The timer sends x-cron-secret (Vault secret via
// cron_vault_secret(); the older CRON_SECRET is still accepted).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { drainSmsOutbox, sendAutoSms } from "../_shared/autoSms.ts";
import { EMAIL_SIGNOFF, OWNER_DISPLAY_NAME } from "../_shared/businessName.mjs";
import { isCronRequest } from "../_shared/cronAuth.ts";
import { addDaysIso } from "../_shared/quietHours.mjs";
import {
  challengeActive,
  challengeClosesInTwoDays,
  challengeOpen,
  challengeParticipants,
  habitReminderDue,
  reminderPlan,
  sessionDayWord,
  sessionReminderDue,
  slotLabel,
} from "../_shared/reminderRules.mjs";
import { sendEmail } from "../_shared/sendEmail.ts";
import { sendPush } from "../_shared/sendPush.ts";
import { offerSlot } from "../_shared/waitlistOffers.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

serve(async (req) => {
  const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  if (!(await isCronRequest(admin, req))) return json({ error: "Unauthorized" }, 401);

  try {
    const now = new Date();
    const plan = reminderPlan(now);
    const today = plan.today;
    const sent: Record<string, number> = {
      session: 0,
      habit: 0,
      challengeCreated: 0,
      challengeWeekly: 0,
      challengeClosing: 0,
      cardExpiring: 0,
      monthlyReview: 0,
    };

    /** One notice per kind + ref + person. False when it already went out. */
    async function claim(kind: string, ref: string, profileId: string): Promise<boolean> {
      const { error } = await admin.from("scheduled_notices").insert({ kind, ref, profile_id: profileId });
      if (!error) return true;
      if ((error as { code?: string }).code !== "23505") console.error(`reminders: claim failed: ${error.message}`);
      return false;
    }

    async function pushTo(profileId: string, title: string, body: string) {
      const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
      await sendPush((rows || []).map((r: { token: string }) => r.token), title, body);
    }

    // Stale waitlist offers (the 15-minute sweep does this too).
    try {
      const nowIso = now.toISOString();
      const { data: stale } = await admin.from("waitlist")
        .select("id, trainer_id, date, slot")
        .eq("status", "offered")
        .lt("offer_expires_at", nowIso);
      for (const entry of stale ?? []) {
        await admin.from("waitlist").update({ status: "declined", declined_at: nowIso }).eq("id", entry.id);
        await offerSlot(entry.trainer_id, entry.date, Number(entry.slot));
      }
    } catch (e) {
      console.error("reminders: waitlist sweep failed:", e instanceof Error ? e.message : String(e));
    }

    // Texts held overnight go out first thing.
    const queue = plan.drainQueue ? await drainSmsOutbox(admin, now) : { sent: 0, skipped: 0, expired: 0 };

    // ---- Session reminders, about 24 hours ahead ----
    if (plan.sessions) {
      const { data: bookings } = await admin.from("bookings")
        .select("id, client_id, date, slot_min, created_at")
        .gte("date", today)
        .lte("date", addDaysIso(today, 2))
        .is("cancelled_at", null);
      for (const b of bookings ?? []) {
        if (!b.client_id) continue;
        if (!sessionReminderDue({ date: b.date, slotMin: b.slot_min, createdAt: b.created_at }, now)) continue;
        if (!(await claim("session", String(b.id), String(b.client_id)))) continue;
        const when = `${sessionDayWord(String(b.date), today)} at ${slotLabel(b.slot_min)}`;
        try {
          await pushTo(b.client_id, "Session reminder", `You have a session ${when}.`);
          await sendAutoSms(admin, { profileId: b.client_id, text: `Reminder: you have a session ${when}.`, kind: "session-reminder", ref: String(b.id) });
          sent.session++;
        } catch (e) {
          console.error("reminders: session reminder failed:", e instanceof Error ? e.message : String(e));
        }
      }
    }

    const needClients = plan.habits || plan.monthly;
    const { data: clients } = needClients
      ? await admin.from("clients").select("profile_id, stripe_customer_id")
      : { data: [] as { profile_id: string; stripe_customer_id: string | null }[] };
    const { data: profiles } = await admin.from("profiles").select("id, name, email, role").is("deleted_at", null);
    const profileById = new Map((profiles || []).map((p: { id: string; name: string | null; email: string | null; role: string }) => [p.id, p]));

    // ---- Habit reminder, 7pm Pacific ----
    if (plan.habits) {
      for (const c of clients ?? []) {
        const profile = profileById.get(c.profile_id);
        if (!profile || profile.role !== "client") continue;
        const { data: recordRow } = await admin.from("client_records").select("data").eq("profile_id", c.profile_id).maybeSingle();
        if (!habitReminderDue(recordRow?.data, today)) continue;
        if (!(await claim("habit", today, c.profile_id))) continue;
        if (profile.email) {
          await sendEmail(
            profile.email,
            "Don't forget your habits today",
            `Hi ${profile.name || "there"},\n\nYou haven't logged today's habits yet. It only takes a minute in the app.\n\n${EMAIL_SIGNOFF}`,
          );
        }
        await pushTo(c.profile_id, "Habit reminder", "You haven't logged today's habits yet.");
        sent.habit++;
      }
    }

    // ---- Challenges: participants only ----
    if (plan.challengeCreated || plan.challengeWeekly || plan.challengeClosing) {
      const { data: challenges } = await admin.from("challenges")
        .select("id, name, start_date, end_date, status, participants")
        .gte("end_date", today);
      for (const ch of challenges ?? []) {
        if (!challengeOpen(ch, today)) continue;
        const name = String(ch.name || "Your challenge");
        for (const profileId of challengeParticipants(ch)) {
          const profile = profileById.get(profileId);
          if (!profile || profile.role !== "client") continue;
          const notices: { kind: string; ref: string; title: string; text: string; key: keyof typeof sent }[] = [];
          if (plan.challengeCreated) {
            const starts = ch.start_date && ch.start_date > today ? ` It starts ${ch.start_date}.` : "";
            notices.push({ kind: "challenge-created", ref: String(ch.id), title: "New challenge", text: `You're in "${name}".${starts} Good luck!`, key: "challengeCreated" });
          }
          if (plan.challengeWeekly && challengeActive(ch, today)) {
            notices.push({ kind: "challenge-weekly", ref: `${ch.id}:${today}`, title: "New week of your challenge", text: `New week of "${name}". It runs through ${ch.end_date}. Keep it up!`, key: "challengeWeekly" });
          }
          if (plan.challengeClosing && challengeClosesInTwoDays(ch, today)) {
            notices.push({ kind: "challenge-closing", ref: String(ch.id), title: "2 days left", text: `"${name}" closes in 2 days (${ch.end_date}). Finish strong!`, key: "challengeClosing" });
          }
          for (const n of notices) {
            if (!(await claim(n.kind, n.ref, profileId))) continue;
            await pushTo(profileId, n.title, n.text);
            if (profile.email) await sendEmail(profile.email, n.title, `Hi ${profile.name || "there"},\n\n${n.text}\n\n${EMAIL_SIGNOFF}`);
            await sendAutoSms(admin, { profileId, text: n.text, kind: n.kind, ref: n.ref });
            sent[n.key]++;
          }
        }
      }
    }

    // ---- 1st of the month, 9am Pacific ----
    if (plan.monthly) {
      const [year, month] = plan.month.split("-").map(Number);
      for (const c of clients ?? []) {
        const profile = profileById.get(c.profile_id);
        if (!profile || profile.role !== "client") continue;

        if (c.stripe_customer_id && profile.email && (await claim("card-expiring", plan.month, c.profile_id))) {
          try {
            const pms = await stripe.paymentMethods.list({ customer: c.stripe_customer_id, type: "card" });
            for (const pm of pms.data) {
              if (!pm.card) continue;
              const monthsUntilExpiry = (pm.card.exp_year - year) * 12 + (pm.card.exp_month - month);
              if (monthsUntilExpiry !== 1) continue;
              await sendEmail(
                profile.email,
                "Your card on file is expiring soon",
                `Hi ${profile.name || "there"},\n\nThe card ending in ${pm.card.last4} on your ${OWNER_DISPLAY_NAME} account expires ${pm.card.exp_month}/${pm.card.exp_year}. Please update your payment method in the app to avoid any interruption.\n\n${EMAIL_SIGNOFF}`,
              );
              await sendAutoSms(admin, {
                profileId: c.profile_id,
                text: `The card ending in ${pm.card.last4} on your account expires ${pm.card.exp_month}/${pm.card.exp_year}. Please update it in the app.`,
                kind: "card-expiring",
                ref: `${plan.month}:${pm.id}`,
              });
              sent.cardExpiring++;
            }
          } catch (e) {
            console.error("reminders: card lookup failed:", e instanceof Error ? e.message : String(e));
          }
        }

        if (profile.email && (await claim("monthly-review", plan.month, c.profile_id))) {
          await sendEmail(
            profile.email,
            "Time for your monthly progress review",
            `Hi ${profile.name || "there"},\n\nIt's a new month — a great time to check in with your coach on your progress and set goals for the weeks ahead.\n\n${EMAIL_SIGNOFF}`,
          );
          await sendAutoSms(admin, {
            profileId: c.profile_id,
            text: "It's a new month, a great time to check in with your coach on your progress.",
            kind: "monthly-review",
            ref: plan.month,
          });
          sent.monthlyReview++;
        }
      }
    }

    console.log(`send-scheduled-reminders: ${JSON.stringify({ ...sent, queue })}`);
    return json({ ok: true, sent, queue });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-scheduled-reminders failed:", message);
    return json({ error: message }, 500);
  }
});
