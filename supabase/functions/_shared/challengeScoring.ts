// Same numbers the leaderboard uses, so a 1st-place claim can be checked
// again on the server. Custom challenges carry scoring_basis; reading only
// template scored them as zero.
// deno-lint-ignore no-explicit-any
type AnyRecord = any;

export function parseLeadingNum(v: unknown): number | null {
  if (v == null) return null;
  const m = String(v).match(/-?\d+(\.\d+)?/);
  return m ? parseFloat(m[0]) : null;
}

export function measurementDrop(record: AnyRecord, field: string, startDate: string, endDate: string): number {
  const series = (record?.measurements || [])
    .filter((m: AnyRecord) => m.date >= startDate && m.date <= endDate && parseLeadingNum(m[field]) != null)
    .map((m: AnyRecord) => ({ date: m.date, value: parseLeadingNum(m[field]) as number }))
    .sort((a: AnyRecord, b: AnyRecord) => (a.date < b.date ? -1 : 1));
  if (series.length < 2) return 0;
  const start = series[0].value;
  const best = Math.min(...series.map((s: AnyRecord) => s.value));
  return Math.max(0, Math.round((start - best) * 10) / 10);
}

const DEFAULT_HABITS = ["water", "steps", "sleep"];

export function calcChallengeScore(clientId: string, challenge: AnyRecord, record: AnyRecord, bookings: AnyRecord[]): number {
  const tpl = challenge.scoringBasis ?? challenge.scoring_basis ?? challenge.template;
  if (tpl === "attendance") {
    return bookings.filter((b) => b.client_id === clientId && b.attendance_status === "checked-in" && b.date >= challenge.startDate && b.date <= challenge.endDate).length;
  }
  if (tpl === "fat-loss" || tpl === "progressive-overload") {
    const entries = (record?.challengeProgress || {})[challenge.id] || [];
    if (!entries.length) return 0;
    return Math.max(...entries.map((e: AnyRecord) => e.value || 0));
  }
  if (tpl === "transformation") return challenge.winner === clientId ? 1 : 0;
  if (tpl === "weight-loss") return measurementDrop(record, "weight", challenge.startDate, challenge.endDate);
  if (tpl === "body-fat") return measurementDrop(record, "bodyfat", challenge.startDate, challenge.endDate);
  if (tpl === "inches-lost") {
    return ["chest", "waist", "hips", "arms", "thighs"].reduce((total, field) => total + measurementDrop(record, field, challenge.startDate, challenge.endDate), 0);
  }
  if (tpl === "30-day" || tpl === "community") {
    const logs = record?.habitLogs || [];
    const habitIds: string[] = (record?.customHabits?.length ? record.customHabits.map((h: AnyRecord) => h.id) : DEFAULT_HABITS)
      .filter((id: string) => (record?.habitConfig || {})[id] !== false);
    if (!habitIds.length) return 0;
    const start = new Date(challenge.startDate + "T00:00:00Z");
    const end = new Date(Math.min(new Date(challenge.endDate + "T00:00:00Z").getTime(), Date.now()));
    const days: string[] = [];
    for (let d = new Date(start); d <= end; d.setUTCDate(d.getUTCDate() + 1)) days.push(d.toISOString().slice(0, 10));
    if (!days.length) return 0;
    const pcts = days.map((day) => {
      const log = logs.find((l: AnyRecord) => l.date === day) || {};
      const done = habitIds.filter((id) => log.checked?.[id]).length;
      return (done / habitIds.length) * 100;
    });
    return Math.round(pcts.reduce((s, v) => s + v, 0) / pcts.length);
  }
  return 0;
}

export function rankParticipants(challenge: AnyRecord, recordsByClient: Record<string, AnyRecord>, bookings: AnyRecord[]) {
  const participants: string[] = challenge.participants || [];
  const leaderboard = participants
    .map((clientId) => ({ clientId, score: calcChallengeScore(clientId, challenge, recordsByClient[clientId] || {}, bookings) }))
    .sort((a, b) => b.score - a.score);
  let rank = 1;
  return leaderboard.map((e, i) => {
    if (i > 0 && leaderboard[i].score < leaderboard[i - 1].score) rank = i + 1;
    return { ...e, rank };
  });
}
