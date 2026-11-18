// Nightly Merit Badge sweep. pg_cron calls it with the Vault password
// (the same apply_requests_cron secret the hourly request job uses).
// Deploy with JWT verification off.
//
// Each call handles a few clients, then hands the rest to the next call so
// the database's web request does not time out. The first call also expires
// Gym Citizen checks that are older than six months and finalizes last
// month's coach badges.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { expireGymCitizen, reconcileBadge, TIME_DRIVEN_BADGES } from "../_shared/badgeEligibility.ts";
import { lastPacificMonth, monthRange, pacificToday } from "../_shared/badgeRules.mjs";
import {
  challengeCoachQualifies,
  checkInQualifies,
  clientMilestoneAwards,
  comebackQualifies,
  fullHouseQualifies,
  habitCoachQualifies,
  prFactoryQualifies,
  retentionQualifies,
  sessionsCoachedQualifies,
} from "../_shared/coachMonth.mjs";

const BATCH_SIZE = 3;
const MAX_CHAIN = 400;

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: any;

async function insertCoachBadge(admin: any, row: { trainer_id: string; badge_key: string; period_month: string; reward_cents: number }) {
  const { error } = await admin.from("coach_merit_badges").insert(row);
  if (error && error.code !== "23505") console.error("coach badge:", row.badge_key, error.message);
}

async function finalizeCoachMonth(admin: any) {
  const monthKey = lastPacificMonth(new Date());
  const range = monthRange(monthKey);
  const { data: settingsRow } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
  const workouts = settingsRow?.data?.workouts || {};
  const scheduling = settingsRow?.data?.scheduling || {};
  const cents: Record<string, number> = {
    full_house: Number(workouts.badgeFullHouseCents) || 0,
    pr_factory: Number(workouts.badgePrFactoryCents) || 0,
    check_in: Number(workouts.badgeCheckInCents) || 0,
    comeback: Number(workouts.badgeComebackCents) || 0,
    habit_coach: Number(workouts.badgeHabitCoachCents) || 0,
    challenge_coach: Number(workouts.badgeChallengeCoachCents) || 0,
    coach_of_month: Number(workouts.badgeCoachOfMonthCents) || 0,
    sessions_coached: Number(workouts.badgeSessionsCoachedCents) || 0,
    retention_streak: Number(workouts.badgeRetentionCents) || 0,
    client_milestone: Number(workouts.badgeClientMilestoneCents) || 0,
  };
  const habitPercent = Number(workouts.meritBadgeHabitPercent) || 80;
  const habitWeeks = Number(workouts.meritBadgeHabitWeeks) || 3;
  const semiPrivateCap = Number(scheduling.semiPrivateCap) || 4;

  const { data: trainers } = await admin.from("trainers").select("profile_id, availability, unavailability");
  const { data: clients } = await admin.from("clients").select("profile_id, primary_trainer_id");
  const { data: bookingRows } = await admin.from("bookings")
    .select("client_id, trainer_id, date, slot_min, attendance_status, cancelled_at");
  const { data: prs } = await admin.from("coach_pr_events").select("trainer_id, client_id, earned_at");
  const { data: challenges } = await admin.from("challenges").select("start_date, end_date, participants");
  const { data: records } = await admin.from("client_records")
    .select("profile_id, habitSettings:data->habitSettings, habitLogs:data->habitLogs, workoutLogs:data->workoutLogs, comms:data->comms");
  const { data: prior } = await admin.from("coach_merit_badges").select("trainer_id, badge_key").eq("badge_key", "coach_of_month");

  const allBookings = (bookingRows || []).map((b: any) => ({
    clientId: b.client_id,
    trainerId: b.trainer_id,
    date: String(b.date).slice(0, 10),
    slotMin: b.slot_min,
    attendance: b.attendance_status,
    cancelled: !!b.cancelled_at,
  }));
  const recordsByClient: Record<string, any> = {};
  for (const r of records || []) {
    recordsByClient[r.profile_id] = {
      habitSettings: r.habitSettings,
      habitLogs: r.habitLogs,
      workoutLogs: r.workoutLogs,
      comms: r.comms,
    };
  }
  const challengeRows = (challenges || []).map((c: any) => ({
    startDate: String(c.start_date),
    endDate: String(c.end_date),
    participantIds: c.participants || [],
  }));
  const priorWins: Record<string, number> = {};
  for (const row of prior || []) priorWins[row.trainer_id] = (priorWins[row.trainer_id] || 0) + 1;

  const scores: { trainerId: string; composite: number; priorWins: number; eligible: boolean }[] = [];
  for (const trainer of trainers || []) {
    const id = trainer.profile_id;
    const mine = allBookings.filter((b: any) => b.trainerId === id);
    const rosterIds = (clients || []).filter((c: any) => c.primary_trainer_id === id).map((c: any) => c.profile_id);
    const myPrs = (prs || []).filter((p: any) => p.trainer_id === id).map((p: any) => ({ clientId: p.client_id, earnedAt: p.earned_at }));
    const args = { rosterIds, recordsByClient, bookings: mine, coachId: id, start: range.start, end: range.end };
    const earned: string[] = [];
    if (fullHouseQualifies({ availability: trainer.availability, unavailability: trainer.unavailability, bookings: mine, start: range.start, end: range.end, semiPrivateCap })) earned.push("full_house");
    if (prFactoryQualifies(myPrs, range.start, range.end)) earned.push("pr_factory");
    if (checkInQualifies(args)) earned.push("check_in");
    if (comebackQualifies(args)) earned.push("comeback");
    if (habitCoachQualifies({ rosterIds, recordsByClient, start: range.start, end: range.end, percent: habitPercent, weeks: habitWeeks })) earned.push("habit_coach");
    if (challengeCoachQualifies({ rosterIds, challenges: challengeRows, start: range.start, end: range.end })) earned.push("challenge_coach");
    if (sessionsCoachedQualifies(mine, range.start, range.end)) earned.push("sessions_coached");
    if (retentionQualifies(mine, monthKey)) earned.push("retention_streak");
    for (const key of earned) {
      await insertCoachBadge(admin, { trainer_id: id, badge_key: key, period_month: monthKey, reward_cents: cents[key] || 0 });
    }
    for (const award of clientMilestoneAwards(allBookings, { coachId: id, start: range.start, end: range.end }) as any[]) {
      await insertCoachBadge(admin, {
        trainer_id: id,
        badge_key: award.badgeKey,
        period_month: monthKey,
        reward_cents: cents.client_milestone || 0,
      });
    }
    const weights: Record<string, number> = { full_house: 0.3, pr_factory: 0.2, check_in: 0.2, comeback: 0.15, habit_coach: 0.1, challenge_coach: 0.05 };
    const composite = Object.entries(weights).reduce((sum, [key, w]) => sum + (earned.includes(key) ? w : 0), 0);
    const completed = mine.filter((b: any) => b.attendance === "checked-in" && b.date >= range.start && b.date <= range.end).length;
    scores.push({ trainerId: id, composite, priorWins: priorWins[id] || 0, eligible: rosterIds.length >= 1 && completed >= 5 });
  }
  const eligible = scores.filter((s) => s.eligible).sort((a, b) => b.composite - a.composite || b.priorWins - a.priorWins);
  if (eligible.length) {
    await insertCoachBadge(admin, {
      trainer_id: eligible[0].trainerId,
      badge_key: "coach_of_month",
      period_month: monthKey,
      reward_cents: cents.coach_of_month || 0,
    });
  }
}

serve(async (req) => {
  const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  const { data: secretRow, error: secretErr } = await admin.rpc("cron_vault_secret");
  if (secretErr) console.error("cron vault read failed");
  const expected = typeof secretRow === "string" ? secretRow : "";
  const cron = req.headers.get("x-cron-secret");
  if (!expected || cron !== expected) return new Response("Forbidden", { status: 403 });

  try {
    let onlyBadge: string | null = null;
    let dryRun = false;
    let after: string | null = null;
    let chain = 0;
    try {
      const body = await req.json();
      onlyBadge = typeof body?.badgeKey === "string" ? body.badgeKey : null;
      dryRun = body?.dryRun === true;
      after = typeof body?.after === "string" ? body.after : null;
      chain = Number.isFinite(body?.chain) ? Number(body.chain) : 0;
    } catch { /* first call, no body */ }

    if (chain === 0 && !dryRun && !onlyBadge) {
      try {
        await finalizeCoachMonth(admin);
      } catch (e) {
        console.error("coach badge finalization failed:", e instanceof Error ? e.message : String(e));
      }
    }

    let q = admin.from("clients").select("profile_id, profiles!inner(deleted_at)")
      .is("profiles.deleted_at", null).order("profile_id", { ascending: true }).limit(BATCH_SIZE);
    if (after) q = q.gt("profile_id", after);
    const { data: clients, error: clientsErr } = await q;
    if (clientsErr) throw clientsErr;

    const badges = onlyBadge ? TIME_DRIVEN_BADGES.filter((b) => b === onlyBadge) : TIME_DRIVEN_BADGES;
    if (onlyBadge && badges.length === 0) {
      return new Response(JSON.stringify({ error: `${onlyBadge} is not swept here.` }), { status: 400, headers: { "Content-Type": "application/json" } });
    }

    let awarded = 0, revoked = 0, expired = 0, failed = 0;
    for (const row of clients ?? []) {
      const clientId = (row as { profile_id: string }).profile_id;
      if (!dryRun) {
        try {
          expired += await expireGymCitizen(admin, clientId);
        } catch (e) {
          failed++;
          console.error("gym citizen expiry", clientId, e instanceof Error ? e.message : String(e));
        }
      }
      for (const badgeKey of badges) {
        try {
          if (dryRun) continue;
          const outcome = await reconcileBadge(admin, clientId, badgeKey);
          if (outcome.outcome === "awarded") awarded++;
          else if (outcome.outcome === "revoked") revoked++;
        } catch (e) {
          failed++;
          console.error(`sweep ${badgeKey} ${clientId}:`, e instanceof Error ? e.message : String(e));
        }
      }
    }

    const rows = clients ?? [];
    const lastId = rows.length ? (rows[rows.length - 1] as { profile_id: string }).profile_id : null;
    const more = rows.length === BATCH_SIZE && lastId !== null;
    let handedOff = false;
    if (more && !dryRun && chain + 1 < MAX_CHAIN) {
      const next = fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/sweep-merit-badges`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-cron-secret": expected },
        body: JSON.stringify({ badgeKey: onlyBadge, after: lastId, chain: chain + 1 }),
      }).catch((e) => console.error("sweep hand-off failed:", e instanceof Error ? e.message : String(e)));
      if (typeof EdgeRuntime?.waitUntil === "function") EdgeRuntime.waitUntil(next);
      handedOff = true;
    }

    const summary = { ok: true, dryRun, batch: chain, clients: rows.length, awarded, revoked, expired, failed, handedOff, lastClientId: lastId, pacificToday: pacificToday() };
    console.log("sweep-merit-badges:", JSON.stringify(summary));
    return new Response(JSON.stringify(summary), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("sweep-merit-badges failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
