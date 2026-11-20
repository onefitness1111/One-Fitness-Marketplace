// Monthly coach badges. Plain data in, rows to save out. The nightly sweep
// and the tests both use this. The app's progress screen uses the same
// numbers, written again in Dart so a coach can see the month as it happens.

import { SESSIONS_COACHED_TARGET, RETENTION_MONTHS, monthsEnding, habitIds, weeklyScore, addDays, pacificParts } from "./badgeRules.mjs";

export { SESSIONS_COACHED_TARGET, RETENTION_MONTHS };

export function capFor(sessionType, semiPrivateCap = 4) {
  if (sessionType === "one-on-one" || sessionType === "assessment-call" || sessionType === "assessment-in-person") return 1;
  if (sessionType === "large-group") return 15;
  return semiPrivateCap;
}

function weekdaySun0(ymd) {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

function slotsOf(raw) {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw.map(Number);
  return Object.values(raw).flat().map(Number);
}

export function offeringsOn(availability, ymd) {
  const wd = String(weekdaySun0(ymd));
  const blocks = Array.isArray(availability) ? availability : [];
  const oneOffs = [];
  const weekly = [];
  for (const block of blocks) {
    const type = block?.sessionType || "";
    const disc = block?.discipline || "";
    const dates = block?.dates || {};
    const byDay = block?.byDay || {};
    const duration = Number(block?.durationMin) || 60;
    for (const slot of slotsOf(dates[ymd])) oneOffs.push({ type, disc, slot, duration });
    for (const slot of slotsOf(byDay[wd] ?? byDay[Number(wd)])) weekly.push({ type, disc, slot, duration });
  }
  const taken = new Set(oneOffs.map((o) => `${o.slot}|${o.type}|${o.disc}`));
  return [...oneOffs, ...weekly.filter((o) => !taken.has(`${o.slot}|${o.type}|${o.disc}`))];
}

// All-day, and any older entry with no times, covers the whole day.
// A start time with no end runs to midnight. A start and end apply on
// every day in the range, and only remove slots that overlap those minutes.
function offeringBlocked(unavailability, ymd, slot, duration) {
  const start = Number(slot);
  const end = start + (Number(duration) || 60);
  return (unavailability || []).some((u) => {
    const from = String(u.startDate || "");
    const to = String(u.endDate || u.startDate || "");
    if (ymd < from || ymd > to) return false;
    const startMin = u.startMin == null || u.startMin === "" ? null : Number(u.startMin);
    const endMin = u.endMin == null || u.endMin === "" ? null : Number(u.endMin);
    const whole = u.allDay === true || (startMin == null && endMin == null);
    if (whole) return true;
    const blockStart = startMin ?? 0;
    const blockEnd = endMin == null ? 24 * 60 : endMin;
    return blockStart < end && blockEnd > start;
  });
}

function eachDay(start, end, fn) {
  const [ys, ms, ds] = start.split("-").map(Number);
  const cur = new Date(Date.UTC(ys, ms - 1, ds));
  const [ye, me, de] = end.split("-").map(Number);
  const last = Date.UTC(ye, me - 1, de);
  while (cur.getTime() <= last) {
    const ymd = cur.toISOString().slice(0, 10);
    fn(ymd);
    cur.setUTCDate(cur.getUTCDate() + 1);
  }
}

export function fullHouseQualifies({ availability, unavailability, bookings, start, end, semiPrivateCap = 4 }) {
  const expected = (bookings || []).filter((b) => !b.cancelled && b.date >= start && b.date <= end);
  if (expected.length === 0) return false;
  const completed = expected.filter((b) => b.attendance === "checked-in").length;
  let capacity = 0;
  eachDay(start, end, (ymd) => {
    for (const o of offeringsOn(availability, ymd)) {
      if (offeringBlocked(unavailability, ymd, o.slot, o.duration)) continue;
      capacity += capFor(o.type, semiPrivateCap);
    }
  });
  const booked = expected.length;
  const utilization = capacity === 0 ? 0 : booked / capacity;
  return completed / expected.length >= 0.9 && utilization >= 0.8;
}

export function prFactoryQualifies(events, start, end) {
  const clients = new Set(
    (events || []).filter((e) => String(e.earnedAt || "").slice(0, 10) >= start && String(e.earnedAt || "").slice(0, 10) <= end).map((e) => e.clientId),
  );
  return clients.size >= 5;
}

export function sessionsCoachedCount(bookings, start, end) {
  return (bookings || []).filter((b) => b.attendance === "checked-in" && !b.cancelled && b.date >= start && b.date <= end).length;
}

export function sessionsCoachedQualifies(bookings, start, end, target = SESSIONS_COACHED_TARGET) {
  return sessionsCoachedCount(bookings, start, end) >= target;
}

// A client who trained with this coach in each of the last N months.
export function retentionQualifies(bookings, monthKey, months = RETENTION_MONTHS) {
  const keys = monthsEnding(monthKey, months);
  const byClient = new Map();
  for (const b of bookings || []) {
    if (b.attendance !== "checked-in" || b.cancelled) continue;
    const month = String(b.date || "").slice(0, 7);
    if (!keys.includes(month)) continue;
    if (!byClient.has(b.clientId)) byClient.set(b.clientId, new Set());
    byClient.get(b.clientId).add(month);
  }
  let n = 0;
  for (const set of byClient.values()) {
    if (keys.every((k) => set.has(k))) n++;
  }
  return n >= 1;
}

const MILESTONES = [10, 25, 50, 100];

// The session that moved a client onto 10, 25, 50, or 100. The coach of
// that session earns the badge. The count is every checked-in session,
// with any coach, in date order. Pass coachId to keep one coach's rows.
export function clientMilestoneAwards(allBookings, { coachId = null, start = null, end = null } = {}) {
  const awards = [];
  const counts = new Map();
  const sorted = [...(allBookings || [])]
    .filter((b) => b.attendance === "checked-in" && !b.cancelled && b.date)
    .sort((a, b) => (a.date === b.date ? (a.slotMin || 0) - (b.slotMin || 0) : a.date < b.date ? -1 : 1));
  for (const b of sorted) {
    const n = (counts.get(b.clientId) || 0) + 1;
    counts.set(b.clientId, n);
    if (!MILESTONES.includes(n)) continue;
    if (coachId && b.trainerId !== coachId) continue;
    if (start && b.date < start) continue;
    if (end && b.date > end) continue;
    awards.push({
      clientId: b.clientId,
      trainerId: b.trainerId,
      count: n,
      badgeKey: `client_milestone_${b.clientId}_${n}`,
      date: b.date,
    });
  }
  return awards;
}

export function challengeCoachQualifies({ rosterIds, challenges, start, end }) {
  const active = (challenges || []).filter((c) => c.startDate <= end && c.endDate >= start);
  const mine = rosterIds || [];
  if (active.length === 0 || mine.length === 0) return false;
  const participants = new Set(active.flatMap((c) => c.participantIds || []));
  const inIt = mine.filter((id) => participants.has(id)).length;
  return inIt / mine.length >= 0.5;
}

function messageDate(id) {
  const micros = Number(id);
  if (!Number.isFinite(micros)) return null;
  return pacificParts(new Date(micros / 1000)).ymd;
}

function hasCheckIn(record, coachId, triggerDate) {
  const windowEnd = addDays(triggerDate, 1);
  for (const m of record?.comms || []) {
    if (m.who !== "trainer" || m.trainerId !== coachId) continue;
    const ts = messageDate(m.id);
    if (ts && ts >= triggerDate && ts <= windowEnd) return true;
  }
  return false;
}

function redTransitions(record) {
  const dates = [...new Set((record?.workoutLogs || []).map((w) => String(w.date || "").slice(0, 10)).filter(Boolean))].sort();
  const out = [];
  for (let i = 1; i < dates.length; i++) {
    const gap = (Date.parse(dates[i] + "T00:00:00Z") - Date.parse(dates[i - 1] + "T00:00:00Z")) / 86400000;
    if (gap > 7) out.push({ transition: addDays(dates[i - 1], 8), returnDate: dates[i] });
  }
  return out;
}

export function checkInQualifies({ rosterIds, recordsByClient, bookings, coachId, start, end }) {
  let triggers = 0;
  let done = 0;
  for (const id of rosterIds || []) {
    const record = recordsByClient?.[id];
    const dates = new Set();
    for (const b of bookings || []) {
      if (b.trainerId && b.trainerId !== coachId) continue;
      if (b.clientId === id && b.attendance === "no-show" && b.date >= start && b.date <= end) dates.add(b.date);
    }
    const late = (bookings || []).filter((b) => (!b.trainerId || b.trainerId === coachId) && b.clientId === id && b.attendance === "late-cancel").map((b) => b.date).sort();
    for (const d of late) {
      const windowStart = addDays(d, -14);
      const count = late.filter((x) => x >= windowStart && x <= d).length;
      if (count >= 2 && d >= start && d <= end) dates.add(d);
    }
    for (const e of redTransitions(record)) {
      if (e.transition >= start && e.transition <= end) dates.add(e.transition);
    }
    for (const d of dates) {
      triggers++;
      if (hasCheckIn(record, coachId, d)) done++;
    }
  }
  return triggers > 0 && done / triggers >= 0.9;
}

export function comebackQualifies({ rosterIds, recordsByClient, bookings, coachId, start, end }) {
  let n = 0;
  for (const id of rosterIds || []) {
    const record = recordsByClient?.[id];
    for (const e of redTransitions(record)) {
      if (e.returnDate < start || e.returnDate > end) continue;
      if (!hasCheckIn(record, coachId, e.transition)) continue;
      const windowEnd = addDays(e.returnDate, 14);
      const sustained = (bookings || []).filter((b) => (!b.trainerId || b.trainerId === coachId) && b.clientId === id && b.attendance === "checked-in" && b.date >= e.returnDate && b.date <= windowEnd).length;
      if (sustained >= 3) n++;
    }
  }
  return n >= 2;
}

export function habitCoachQualifies({ rosterIds, recordsByClient, start, end, percent = 80, weeks = 3 }) {
  const eligible = (rosterIds || []).filter((id) => habitIds(recordsByClient?.[id]).length > 0);
  if (!eligible.length) return false;
  const weekEnds = [];
  let d = addDays(start, 6);
  while (d <= end) {
    weekEnds.push(d);
    d = addDays(d, 7);
  }
  let qualifying = 0;
  for (const id of eligible) {
    const record = recordsByClient[id];
    const ids = habitIds(record);
    let streak = 0;
    let best = 0;
    for (const we of weekEnds) {
      if (weeklyScore(record, ids, we) >= percent) {
        streak++;
        if (streak > best) best = streak;
      } else streak = 0;
    }
    if (best >= weeks) qualifying++;
  }
  return qualifying / eligible.length >= 0.7;
}

export function coachOfTheMonth(scores) {
  const eligible = (scores || []).filter((s) => s.eligible);
  if (eligible.length === 0) return null;
  eligible.sort((a, b) => b.composite - a.composite || (b.priorWins || 0) - (a.priorWins || 0) || String(a.trainerId).localeCompare(String(b.trainerId)));
  return eligible[0].trainerId;
}
