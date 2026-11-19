// Pure Merit Badge rules. The edge functions load the database, then call
// these. Tests cover the rules without a database.
//
// Month boundaries use America/Los_Angeles. The old check used UTC, so a
// session late on the last evening of a Pacific month was counted in the
// next month, and a habit logged that evening could fall outside the
// streak the server was scoring.
//
// Early Bird, Daytimer, and Night Owl used to require a recurring
// membership AND a session cap. A package client, and a membership with
// no cap, could never qualify. That is why those badges stayed at zero
// even when the sessions were all in one window. Habit had the same date
// bug, and nobody has a habit log stored yet, so there was also nothing
// to award.

export const PACIFIC = "America/Los_Angeles";

// The food log migration (20261118210000_food_log.sql) does not create its
// own table. The real log is client_records.data.foodLog: a day, then a
// meal, then the lines. Nutrition Streak reads that object.
export const FOOD_LOG_TABLE = "client_records";
export const FOOD_LOG_KEY = "foodLog";

export const SESSION_MILESTONES = [10, 25, 50, 100];
export const NUTRITION_STREAK_DAYS = 7;
export const SESSIONS_COACHED_TARGET = 20;
export const RETENTION_MONTHS = 3;
export const GOAL_WEIGHT_POUNDS = 0.5;
export const GOAL_INCHES = 1;

const DEFAULT_HABIT_IDS = ["water", "sleep", "meal", "supps", "workout", "stretch", "steps"];

export const TIME_WINDOWS = {
  early_bird: (min) => min < 9 * 60,
  daytimer: (min) => min >= 9 * 60 && min < 18 * 60,
  night_owl: (min) => min >= 18 * 60,
};

// Once earned, the nightly sweep must not take these back.
export const STICKY_BADGES = new Set([
  "champion",
  "first_session",
  "one_year",
  "goal_reached",
  "sessions_10",
  "sessions_25",
  "sessions_50",
  "sessions_100",
]);

export function milestoneKey(count) {
  return `sessions_${count}`;
}

export function isForceAward(earnedMethod) {
  return earnedMethod === "force";
}

// A force-assigned badge stays, even when the nightly rules no longer match.
export function mayRevoke(earnedMethod, badgeKey) {
  if (isForceAward(earnedMethod)) return false;
  if (STICKY_BADGES.has(badgeKey)) return false;
  return true;
}

export function pacificParts(date) {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: PACIFIC,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hourCycle: "h23",
  });
  const parts = {};
  for (const p of fmt.formatToParts(date)) parts[p.type] = p.value;
  return {
    year: parts.year,
    month: parts.month,
    day: parts.day,
    ymd: `${parts.year}-${parts.month}-${parts.day}`,
  };
}

export function pacificToday(now = new Date()) {
  return pacificParts(now).ymd;
}

// The calendar month before the Pacific month that contains [now].
export function lastPacificMonth(now = new Date()) {
  const { year, month } = pacificParts(now);
  let y = Number(year);
  let m = Number(month) - 1;
  if (m < 1) {
    m = 12;
    y -= 1;
  }
  return `${y}-${String(m).padStart(2, "0")}`;
}

export function addDays(ymd, days) {
  const [y, m, d] = ymd.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + days);
  const yy = dt.getUTCFullYear();
  const mm = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(dt.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

export function daysInMonth(monthKey) {
  const [y, m] = monthKey.split("-").map(Number);
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

export function monthRange(monthKey) {
  const last = daysInMonth(monthKey);
  return { start: `${monthKey}-01`, end: `${monthKey}-${String(last).padStart(2, "0")}` };
}

export function shiftMonth(monthKey, delta) {
  let [y, m] = monthKey.split("-").map(Number);
  m += delta;
  while (m < 1) {
    m += 12;
    y -= 1;
  }
  while (m > 12) {
    m -= 12;
    y += 1;
  }
  return `${y}-${String(m).padStart(2, "0")}`;
}

export function monthsEnding(monthKey, count) {
  const out = [];
  for (let i = count - 1; i >= 0; i--) out.push(shiftMonth(monthKey, -i));
  return out;
}

function inWindow(slotMin, windowFn) {
  return slotMin != null && Number.isFinite(Number(slotMin)) && windowFn(Number(slotMin));
}

// Membership with a cap: every one of last month's completed sessions, and
// the count must equal the cap (including a same-month top-up).
// No cap: every completed session last month is in the window, and there
// was at least one.
export function monthWindowQualifies({ cap, sessions, windowFn }) {
  const list = sessions || [];
  if (list.length === 0) return false;
  if (cap != null && Number(cap) > 0 && list.length !== Number(cap)) return false;
  return list.every((s) => inWindow(s.slotMin, windowFn));
}

// A package with a cap is earned once, when the last session of THAT
// package is completed, and only if every session in the package sat in
// the window. It is not a monthly badge.
export function packageWindowQualifies({ cap, sessions, windowFn }) {
  if (cap == null || Number(cap) <= 0) return false;
  const list = sessions || [];
  if (list.length !== Number(cap)) return false;
  return list.every((s) => inWindow(s.slotMin, windowFn));
}

// Which rule applies. Returns null when this plan kind cannot earn it.
export function timeWindowQualifies({ planKind, cap, packageSessions, monthSessions, windowFn }) {
  if (planKind === "package" && cap != null && Number(cap) > 0) {
    return {
      qualifies: packageWindowQualifies({ cap, sessions: packageSessions, windowFn }),
      sticky: true,
    };
  }
  if (planKind === "membership" || planKind === "package") {
    return {
      qualifies: monthWindowQualifies({ cap: cap != null && Number(cap) > 0 ? cap : null, sessions: monthSessions, windowFn }),
      sticky: false,
    };
  }
  return { qualifies: false, sticky: false };
}

export function habitIds(record) {
  const enabled = record?.habitSettings?.enabled || [];
  const custom = (record?.habitSettings?.custom || []).map((h) => h?.id).filter(Boolean);
  return [...DEFAULT_HABIT_IDS.filter((id) => enabled.includes(id)), ...custom];
}

function habitLog(record, date) {
  const logs = record?.habitLogs || [];
  return logs.find((l) => l?.date === date) || { checked: {} };
}

// Seven Pacific calendar days ending on endYmd, inclusive. Average of each
// day's completion percent.
export function weeklyScore(record, ids, endYmd) {
  if (!ids.length) return 0;
  let total = 0;
  for (let i = 0; i < 7; i++) {
    const date = addDays(endYmd, -i);
    const log = habitLog(record, date);
    const done = ids.filter((id) => log.checked?.[id]).length;
    total += (done / ids.length) * 100;
  }
  return total / 7;
}

export function habitQualifies(record, { todayYmd, percent = 80, weeks = 3 } = {}) {
  const ids = habitIds(record);
  if (!ids.length) return false;
  for (let w = 0; w < weeks; w++) {
    const end = addDays(todayYmd, -w * 7);
    if (weeklyScore(record, ids, end) < percent) return false;
  }
  return true;
}

export function hasRecentEntry(entries, cutoffYmd) {
  return (entries || []).some((e) => e?.date && String(e.date).slice(0, 10) >= cutoffYmd);
}

export function sessionMilestoneHits(completedCount) {
  const hits = [];
  if (completedCount >= 1) hits.push("first_session");
  for (const n of SESSION_MILESTONES) {
    if (completedCount >= n) hits.push(milestoneKey(n));
  }
  return hits;
}

export function oneYearQualifies(joinedYmd, todayYmd) {
  if (!joinedYmd || !todayYmd) return false;
  return todayYmd >= addDays(String(joinedYmd).slice(0, 10), 365);
}

export function foodLogDates(foodLog) {
  const days = foodLog?.days;
  if (!days || typeof days !== "object") return [];
  const out = [];
  for (const [date, slots] of Object.entries(days)) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) continue;
    const lists = slots && typeof slots === "object" ? Object.values(slots) : [];
    const any = lists.some((lines) => Array.isArray(lines) && lines.length > 0);
    if (any) out.push(date);
  }
  return out.sort();
}

export function nutritionStreakQualifies(dates, todayYmd, days = NUTRITION_STREAK_DAYS) {
  const set = new Set(dates || []);
  if (set.size === 0) return false;
  // Today can still be empty. Yesterday's finished streak still counts
  // until the client has had the day to log.
  const ends = [todayYmd, addDays(todayYmd, -1)];
  return ends.some((end) => {
    for (let i = 0; i < days; i++) {
      if (!set.has(addDays(end, -i))) return false;
    }
    return true;
  });
}

// Last month was perfect when they finished at least one session and every
// session they were still expected to attend was checked in. An early
// cancel is them giving the session back, so it does not count against them.
export function perfectAttendanceQualifies(bookings) {
  const expected = (bookings || []).filter((b) => b.attendance !== "early-cancel" && !b.cancelled);
  if (expected.length === 0) return false;
  return expected.every((b) => b.attendance === "checked-in");
}

function leadingNumber(value) {
  if (value == null) return null;
  const m = String(value).match(/-?\d+(\.\d+)?/);
  return m ? Number(m[0]) : null;
}

export function goalReachedQualifies({ measurements, goalWeight }) {
  const rows = [...(measurements || [])].filter((m) => m?.date).sort((a, b) => String(a.date).localeCompare(String(b.date)));
  if (goalWeight != null && Number.isFinite(Number(goalWeight)) && rows.length) {
    const latest = [...rows].reverse().map((m) => leadingNumber(m.weight)).find((n) => n != null);
    if (latest != null && Math.abs(latest - Number(goalWeight)) <= GOAL_WEIGHT_POUNDS) return true;
  }
  const fields = ["chest", "waist", "hips", "arms", "thighs"];
  for (const field of fields) {
    const series = rows.map((m) => leadingNumber(m[field])).filter((n) => n != null);
    if (series.length < 2) continue;
    if (series[0] - series[series.length - 1] >= GOAL_INCHES) return true;
  }
  return false;
}

export function championQualifies({ ended, winnerId, clientId, rank }) {
  if (!ended) return false;
  if (winnerId) return winnerId === clientId;
  return rank === 1;
}

export function bundleKeys(event) {
  if (event === "after_session") {
    return ["early_bird", "daytimer", "night_owl", "first_session", "sessions_10", "sessions_25", "sessions_50", "sessions_100", "one_year", "perfect_attendance"];
  }
  if (event === "after_habit") return ["habit"];
  if (event === "after_photo") return ["progress_tracker_photo"];
  if (event === "after_measurement") return ["progress_tracker_measurements", "goal_reached"];
  if (event === "after_workout") return ["progress_tracker_workout"];
  if (event === "after_food") return ["nutrition_streak"];
  return [event];
}

export const BADGE_NAMES = {
  one_fitness: "ONE Fitness",
  early_bird: "Early Bird",
  daytimer: "Daytimer",
  night_owl: "Night Owl",
  progress_tracker: "Progress Tracker",
  progress_tracker_photo: "Progress Photo",
  progress_tracker_measurements: "Measurements",
  progress_tracker_workout: "Log Workout",
  record_breaker: "PR",
  community_builder: "Community Builder",
  squad: "Squad",
  champion: "Champion",
  habit: "Habit",
  gym_citizen: "Gym Citizen",
  first_session: "First Session",
  sessions_10: "10 Sessions",
  sessions_25: "25 Sessions",
  sessions_50: "50 Sessions",
  sessions_100: "100 Sessions",
  one_year: "One Year",
  nutrition_streak: "Nutrition Streak",
  perfect_attendance: "Perfect Attendance",
  goal_reached: "Goal Reached",
};
