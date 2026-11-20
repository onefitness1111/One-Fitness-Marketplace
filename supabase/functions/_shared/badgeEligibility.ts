// Loads one client's live rows and applies badgeRules.mjs. The on-demand
// award and the nightly sweep both come through here, so they cannot disagree.
//
// deno-lint-ignore-file no-explicit-any
import { syncMeritBadgePoints } from "./meritBadgePoints.ts";
import { GYM_CITIZEN_SUB_BADGE_KEYS } from "./gymCitizenSubBadges.ts";
import { PROGRESS_TRACKER_SUB_BADGE_KEYS } from "./progressTrackerSubBadges.ts";
import { rankParticipants } from "./challengeScoring.ts";
import { notifyBadgeEarned } from "./badgeNotify.ts";
import { clientMilestoneAwards } from "./coachMonth.mjs";
import {
  addDays,
  bundleKeys,
  championQualifies,
  foodLogDates,
  goalReachedQualifies,
  habitQualifies,
  hasRecentEntry,
  lastPacificMonth,
  mayRevoke,
  nutritionStreakQualifies,
  oneYearQualifies,
  pacificToday,
  perfectAttendanceQualifies,
  sessionMilestoneHits,
  timeWindowQualifies,
  TIME_WINDOWS,
  FOOD_LOG_TABLE,
  FOOD_LOG_KEY,
} from "./badgeRules.mjs";

const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 180;
const GIVE_BACK = new Set(["early-cancel", "late-cancel", "no-show"]);

export const TIME_DRIVEN_BADGES = [
  "early_bird", "daytimer", "night_owl",
  "community_builder", "habit",
  "nutrition_streak", "perfect_attendance", "one_year",
  "first_session", "sessions_10", "sessions_25", "sessions_50", "sessions_100",
  "goal_reached",
  ...PROGRESS_TRACKER_SUB_BADGE_KEYS,
];

type Cache = {
  client?: any;
  plan?: any;
  bookings?: any[];
  record?: any;
  profile?: any;
  settings?: any;
  foodDates?: string[];
};

function cache(): Cache {
  return {};
}

async function clientRow(admin: any, clientId: string, c: Cache) {
  if (!c.client) {
    const { data } = await admin.from("clients")
      .select("profile_id, membership_plan_id, session_count_override, session_count_override_month, plans, primary_trainer_id")
      .eq("profile_id", clientId).maybeSingle();
    c.client = data || {};
  }
  return c.client;
}

async function planRow(admin: any, c: Cache, client: any) {
  if (c.plan !== undefined) return c.plan;
  if (!client?.membership_plan_id) {
    c.plan = null;
    return null;
  }
  const { data } = await admin.from("membership_plans").select("id, data").eq("id", client.membership_plan_id).maybeSingle();
  c.plan = data || null;
  return c.plan;
}

async function bookings(admin: any, clientId: string, c: Cache) {
  if (!c.bookings) {
    const { data } = await admin.from("bookings")
      .select("id, client_id, trainer_id, date, slot_min, session_type, attendance_status, cancelled_at, is_physical_assessment, plan_id")
      .eq("client_id", clientId);
    c.bookings = data || [];
  }
  return c.bookings;
}

async function record(admin: any, clientId: string, c: Cache) {
  if (!c.record) {
    const { data } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
    c.record = data?.data || {};
  }
  return c.record;
}

async function profile(admin: any, clientId: string, c: Cache) {
  if (!c.profile) {
    const { data } = await admin.from("profiles").select("created_at").eq("id", clientId).maybeSingle();
    c.profile = data || {};
  }
  return c.profile;
}

async function settings(admin: any, c: Cache) {
  if (!c.settings) {
    const { data } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
    c.settings = data?.data || {};
  }
  return c.settings;
}

function completed(b: any) {
  return b.attendance_status === "checked-in" && !b.cancelled_at;
}

function countsForWindow(b: any, allowed: string[]) {
  if (!completed(b) || b.is_physical_assessment) return false;
  if (allowed.length && !allowed.includes(b.session_type)) return false;
  return true;
}

function capFor(client: any, plan: any, monthKey: string): number | null {
  if (!plan) return null;
  const data = plan.data || {};
  let cap = data.maxSessions == null || data.maxSessions === "" ? null : Number(data.maxSessions);
  if (!Number.isFinite(cap as number) || (cap as number) <= 0) cap = null;
  const override = client?.session_count_override;
  const overrideMonth = client?.session_count_override_month;
  if (override != null) {
    const stale = data.kind === "membership" && overrideMonth && overrideMonth !== monthKey;
    if (!stale) cap = Number(override);
  }
  if (data.kind === "membership" && Array.isArray(client?.plans)) {
    for (const e of client.plans) {
      if (e?.planId === plan.id && e?.status === "active" && e?.rolloverMonth === monthKey) {
        cap = (cap || 0) + (Number(e.rolloverSessions) || 0);
      }
    }
  }
  return cap && cap > 0 ? cap : null;
}

async function foodDates(admin: any, clientId: string, c: Cache): Promise<string[]> {
  if (c.foodDates) return c.foodDates;
  // The nutrition update stores the log on the client record, under
  // data.foodLog (days -> meal -> lines). There is no food_logs table.
  const rec = await record(admin, clientId, c);
  c.foodDates = foodLogDates(rec?.[FOOD_LOG_KEY]);
  return c.foodDates;
}

export async function checkQualifies(admin: any, badgeKey: string, clientId: string, c: Cache = cache(), now = new Date(), pinnedPlanId: string | null = null): Promise<{ qualifies: boolean; reason: string; sourceRefId?: string | null }> {
  const today = pacificToday(now);
  const monthKey = lastPacificMonth(now);

  if (badgeKey === "one_fitness") {
    const client = await clientRow(admin, clientId, c);
    return client?.membership_plan_id
      ? { qualifies: true, reason: "" }
      : { qualifies: false, reason: "No active membership or package." };
  }

  if (badgeKey === "early_bird" || badgeKey === "daytimer" || badgeKey === "night_owl") {
    const client = await clientRow(admin, clientId, c);
    let plan = await planRow(admin, c, client);
    if (pinnedPlanId && pinnedPlanId !== plan?.id) {
      const { data } = await admin.from("membership_plans").select("id, data").eq("id", pinnedPlanId).maybeSingle();
      plan = data || null;
    }
    const kind = plan?.data?.kind;
    if (!plan || (kind !== "membership" && kind !== "package")) {
      return { qualifies: false, reason: "No active membership or package." };
    }
    const rows = await bookings(admin, clientId, c);
    const allowed: string[] = plan.data?.allowedTypes || [];
    const windowFn = (TIME_WINDOWS as Record<string, (n: number) => boolean>)[badgeKey];
    const relevant = rows.filter((b: any) => countsForWindow(b, allowed)).map((b: any) => ({
      date: String(b.date).slice(0, 10),
      slotMin: b.slot_min,
      planId: b.plan_id,
    }));
    const cap = capFor(client, plan, monthKey);
    const tagged = relevant.filter((s: any) => s.planId && s.planId === plan.id);
    const packageSessions = tagged.length ? tagged : relevant;
    const monthSessions = relevant.filter((s: any) => s.date.slice(0, 7) === monthKey);
    const decision = timeWindowQualifies({ planKind: kind, cap, packageSessions, monthSessions, windowFn });
    return decision.qualifies
      ? { qualifies: true, reason: "", sourceRefId: decision.sticky ? `package:${plan.id}` : `month:${monthKey}` }
      : { qualifies: false, reason: "The sessions for this window are not all in it yet." };
  }

  if (PROGRESS_TRACKER_SUB_BADGE_KEYS.includes(badgeKey)) {
    const rec = await record(admin, clientId, c);
    const cutoff = addDays(today, -180);
    if (badgeKey === "progress_tracker_photo") {
      return hasRecentEntry(rec.photos, cutoff) ? { qualifies: true, reason: "" } : { qualifies: false, reason: "No progress photo in the last 6 months." };
    }
    if (badgeKey === "progress_tracker_measurements") {
      return hasRecentEntry(rec.measurements, cutoff) ? { qualifies: true, reason: "" } : { qualifies: false, reason: "No measurement in the last 6 months." };
    }
    const logs = (rec.workoutLogs || []).filter((l: any) => l.loggedBy === "client");
    return hasRecentEntry(logs, cutoff) ? { qualifies: true, reason: "" } : { qualifies: false, reason: "No workout you logged yourself in the last 6 months." };
  }

  if (badgeKey === "habit") {
    const s = await settings(admin, c);
    const rec = await record(admin, clientId, c);
    const percent = s?.workouts?.meritBadgeHabitPercent ?? 80;
    const weeks = s?.workouts?.meritBadgeHabitWeeks ?? 3;
    return habitQualifies(rec, { todayYmd: today, percent, weeks })
      ? { qualifies: true, reason: "" }
      : { qualifies: false, reason: "Habit consistency is not there for the required weeks." };
  }

  if (badgeKey === "squad") {
    const { data: squads } = await admin.from("squads").select("member_ids");
    const inAny = (squads || []).some((s: any) => (s.member_ids || []).includes(clientId));
    return inAny ? { qualifies: true, reason: "" } : { qualifies: false, reason: "Not in a squad." };
  }

  if (badgeKey === "community_builder") {
    return { qualifies: false, reason: "Community Builder is granted when a referral is confirmed." };
  }

  if (badgeKey === "first_session" || badgeKey.startsWith("sessions_")) {
    const rows = await bookings(admin, clientId, c);
    const n = rows.filter(completed).length;
    const hits = sessionMilestoneHits(n);
    return hits.includes(badgeKey) ? { qualifies: true, reason: "" } : { qualifies: false, reason: "Not enough completed sessions yet." };
  }

  if (badgeKey === "one_year") {
    const p = await profile(admin, clientId, c);
    const joined = p?.created_at ? String(p.created_at).slice(0, 10) : "";
    return oneYearQualifies(joined, today) ? { qualifies: true, reason: "" } : { qualifies: false, reason: "The one-year date has not arrived." };
  }

  if (badgeKey === "nutrition_streak") {
    const dates = await foodDates(admin, clientId, c);
    return nutritionStreakQualifies(dates, today)
      ? { qualifies: true, reason: "" }
      : { qualifies: false, reason: "No 7-day food log streak yet." };
  }

  if (badgeKey === "perfect_attendance") {
    const rows = await bookings(admin, clientId, c);
    const monthRows = rows.filter((b: any) => String(b.date).slice(0, 7) === monthKey).map((b: any) => ({
      attendance: b.attendance_status,
      cancelled: !!b.cancelled_at,
    }));
    return perfectAttendanceQualifies(monthRows)
      ? { qualifies: true, reason: "", sourceRefId: `month:${monthKey}` }
      : { qualifies: false, reason: "Last month was not perfect attendance." };
  }

  if (badgeKey === "goal_reached") {
    const rec = await record(admin, clientId, c);
    const goal = rec?.intake?.nutritional?.answers?.goalWeight ?? rec?.intake?.personalTraining?.answers?.goalWeight;
    const goalWeight = goal == null ? null : Number(String(goal).match(/-?\d+(\.\d+)?/)?.[0]);
    return goalReachedQualifies({ measurements: rec.measurements || [], goalWeight: Number.isFinite(goalWeight) ? goalWeight : null })
      ? { qualifies: true, reason: "" }
      : { qualifies: false, reason: "The weight or inch goal is not reached yet." };
  }

  return { qualifies: false, reason: `Unknown badge: ${badgeKey}` };
}

async function cascadeProgress(admin: any, clientId: string): Promise<string | null> {
  const { data: activeSubs } = await admin.from("merit_badges").select("badge_key")
    .eq("client_id", clientId).in("badge_key", PROGRESS_TRACKER_SUB_BADGE_KEYS).is("revoked_at", null);
  const activeCount = (activeSubs || []).length;
  const { data: parent } = await admin.from("merit_badges").select("id, earned_method")
    .eq("client_id", clientId).eq("badge_key", "progress_tracker").is("revoked_at", null).maybeSingle();
  if (activeCount >= PROGRESS_TRACKER_SUB_BADGE_KEYS.length && !parent) {
    const { error } = await admin.from("merit_badges").insert({ client_id: clientId, badge_key: "progress_tracker", earned_method: "automatic" });
    if (error && error.code !== "23505") throw error;
    if (!error) return "progress_tracker";
  } else if (activeCount < PROGRESS_TRACKER_SUB_BADGE_KEYS.length && parent && mayRevoke(parent.earned_method, "progress_tracker")) {
    await admin.from("merit_badges").update({ revoked_at: new Date().toISOString(), revoked_by_user_id: null }).eq("id", parent.id);
  }
  return null;
}

async function awardCoachMilestone(admin: any, clientId: string, c: Cache) {
  const rows = await bookings(admin, clientId, c);
  const awards = clientMilestoneAwards(rows.map((b: any) => ({
    clientId: b.client_id,
    trainerId: b.trainer_id,
    date: String(b.date).slice(0, 10),
    slotMin: b.slot_min,
    attendance: b.attendance_status,
    cancelled: !!b.cancelled_at,
  })));
  if (!awards.length) return;
  const s = await settings(admin, c);
  const cents = Number(s?.workouts?.badgeClientMilestoneCents) || 0;
  for (const a of awards as any[]) {
    if (!a.trainerId) continue;
    const { error } = await admin.from("coach_merit_badges").insert({
      trainer_id: a.trainerId,
      badge_key: a.badgeKey,
      period_month: String(a.date).slice(0, 7),
      reward_cents: cents,
    });
    if (error && error.code !== "23505") console.error("coach milestone:", error.message);
  }
}

export type ReconcileOutcome = "awarded" | "revoked" | "unchanged";

export async function reconcileBadge(admin: any, clientId: string, badgeKey: string, c: Cache = cache(), now = new Date()): Promise<{ outcome: ReconcileOutcome; awarded: string[] }> {
  const { data: existing } = await admin.from("merit_badges")
    .select("id, earned_at, earned_method, source_ref_id")
    .eq("client_id", clientId).eq("badge_key", badgeKey).is("revoked_at", null).maybeSingle();

  if (existing) {
    if (!mayRevoke(existing.earned_method, badgeKey)) return { outcome: "unchanged", awarded: [] };
    let still = false;
    if (badgeKey === "community_builder") {
      still = Date.now() - new Date(existing.earned_at).getTime() < SIX_MONTHS_MS;
    } else     if (String(existing.source_ref_id || "").startsWith("package:")) {
      const pinned = String(existing.source_ref_id).slice("package:".length);
      const check = await checkQualifies(admin, badgeKey, clientId, c, now, pinned);
      still = !!check.qualifies && check.sourceRefId === existing.source_ref_id;
    } else {
      still = (await checkQualifies(admin, badgeKey, clientId, c, now)).qualifies;
    }
    if (still) return { outcome: "unchanged", awarded: [] };
    const { error } = await admin.from("merit_badges")
      .update({ revoked_at: new Date().toISOString(), revoked_by_user_id: null }).eq("id", existing.id);
    if (error) throw error;
    if (PROGRESS_TRACKER_SUB_BADGE_KEYS.includes(badgeKey)) await cascadeProgress(admin, clientId);
    await syncMeritBadgePoints(admin, clientId);
    return { outcome: "revoked", awarded: [] };
  }

  if (badgeKey === "champion") return { outcome: "unchanged", awarded: [] };
  const check = await checkQualifies(admin, badgeKey, clientId, c, now);
  if (!check.qualifies) return { outcome: "unchanged", awarded: [] };

  const { error } = await admin.from("merit_badges").insert({
    client_id: clientId,
    badge_key: badgeKey,
    earned_method: "automatic",
    source_ref_id: check.sourceRefId ?? null,
  });
  if (error) {
    if (error.code === "23505") return { outcome: "unchanged", awarded: [] };
    throw error;
  }
  const awarded = [badgeKey];
  if (PROGRESS_TRACKER_SUB_BADGE_KEYS.includes(badgeKey)) {
    const parent = await cascadeProgress(admin, clientId);
    if (parent) awarded.push(parent);
  }
  if (badgeKey.startsWith("sessions_")) await awardCoachMilestone(admin, clientId, c);
  await syncMeritBadgePoints(admin, clientId);
  for (const key of awarded) await notifyBadgeEarned(admin, clientId, key);
  return { outcome: "awarded", awarded };
}

export async function awardChampion(admin: any, clientId: string, sourceRefId: string, now = new Date()): Promise<{ outcome: ReconcileOutcome; awarded: string[]; reason?: string }> {
  const { data: existing } = await admin.from("merit_badges")
    .select("id, earned_method").eq("client_id", clientId).eq("badge_key", "champion").is("revoked_at", null).maybeSingle();
  if (existing) return { outcome: "unchanged", awarded: [] };

  const { data: challenge } = await admin.from("challenges").select("*").eq("id", sourceRefId).maybeSingle();
  if (!challenge) return { outcome: "unchanged", awarded: [], reason: "Challenge not found." };
  const today = pacificToday(now);
  const ended = String(challenge.end_date) < today;
  const participants: string[] = challenge.participants || [];
  if (!participants.includes(clientId)) return { outcome: "unchanged", awarded: [], reason: "Not a participant in that challenge." };

  let rank: number | null = null;
  if (!challenge.winner) {
    const { data: recordRows } = await admin.from("client_records").select("profile_id, data").in("profile_id", participants);
    const recordsByClient: Record<string, any> = {};
    (recordRows || []).forEach((r: any) => { recordsByClient[r.profile_id] = r.data; });
    const { data: bookingRows } = await admin.from("bookings").select("client_id, attendance_status, date").in("client_id", participants);
    const ranked = rankParticipants(
      { ...challenge, startDate: challenge.start_date, endDate: challenge.end_date },
      recordsByClient,
      bookingRows || [],
    );
    rank = ranked.find((r) => r.clientId === clientId)?.rank ?? null;
  }
  if (!championQualifies({ ended, winnerId: challenge.winner, clientId, rank })) {
    return { outcome: "unchanged", awarded: [], reason: "This client is not the champion of that challenge." };
  }
  const { error } = await admin.from("merit_badges").insert({
    client_id: clientId, badge_key: "champion", earned_method: "automatic", source_ref_id: sourceRefId,
  });
  if (error) {
    if (error.code === "23505") return { outcome: "unchanged", awarded: [] };
    throw error;
  }
  await syncMeritBadgePoints(admin, clientId);
  await notifyBadgeEarned(admin, clientId, "champion");
  return { outcome: "awarded", awarded: ["champion"] };
}

export async function expireGymCitizen(admin: any, clientId: string): Promise<number> {
  const { data: activeSubs } = await admin.from("merit_badges")
    .select("id, earned_at").eq("client_id", clientId).in("badge_key", GYM_CITIZEN_SUB_BADGE_KEYS).is("revoked_at", null);
  const now = Date.now();
  const expired = (activeSubs || []).filter((r: { earned_at: string }) => now - new Date(r.earned_at).getTime() > SIX_MONTHS_MS);
  if (!expired.length) return 0;
  const nowIso = new Date().toISOString();
  const { error } = await admin.from("merit_badges").update({ revoked_at: nowIso, revoked_by_user_id: null }).in("id", expired.map((r: { id: string }) => r.id));
  if (error) throw error;
  const remaining = (activeSubs || []).length - expired.length;
  if (remaining < GYM_CITIZEN_SUB_BADGE_KEYS.length) {
    const { data: parent } = await admin.from("merit_badges").select("id, earned_method")
      .eq("client_id", clientId).eq("badge_key", "gym_citizen").is("revoked_at", null).maybeSingle();
    if (parent && mayRevoke(parent.earned_method, "gym_citizen")) {
      await admin.from("merit_badges").update({ revoked_at: nowIso, revoked_by_user_id: null }).eq("id", parent.id);
      await syncMeritBadgePoints(admin, clientId);
    }
  }
  return expired.length;
}

export async function awardRecordBreaker(admin: any, clientId: string) {
  const { data: existing } = await admin.from("merit_badges")
    .select("id").eq("client_id", clientId).eq("badge_key", "record_breaker").is("revoked_at", null).maybeSingle();
  if (existing) return { outcome: "unchanged", awarded: [] as string[] };
  const { error } = await admin.from("merit_badges").insert({
    client_id: clientId,
    badge_key: "record_breaker",
    earned_method: "automatic",
  });
  if (error) {
    if (error.code === "23505") return { outcome: "unchanged", awarded: [] as string[] };
    throw error;
  }
  return { outcome: "awarded", awarded: ["record_breaker"] };
}

export async function runBadgeEvent(admin: any, clientId: string, eventOrKey: string, sourceRefId?: string | null) {
  if (eventOrKey === "record_breaker") return awardRecordBreaker(admin, clientId);
  if (eventOrKey === "champion") {
    if (!sourceRefId) throw new Error("sourceRefId (challenge id) is required.");
    return awardChampion(admin, clientId, sourceRefId);
  }
  const keys = bundleKeys(eventOrKey);
  const c = cache();
  const awarded: string[] = [];
  let reason = "";
  for (const key of keys) {
    const result = await reconcileBadge(admin, clientId, key, c);
    awarded.push(...result.awarded);
    if (!result.awarded.length && keys.length === 1) {
      const check = await checkQualifies(admin, key, clientId, c);
      reason = check.reason;
    }
  }
  return { outcome: awarded.length ? "awarded" : "unchanged", awarded, reason };
}

export { FOOD_LOG_TABLE, FOOD_LOG_KEY };
