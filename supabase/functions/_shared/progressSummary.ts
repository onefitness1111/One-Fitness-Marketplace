// Same rules as lib/core/utils/progress_summary.dart, for the monthly email.
// Dates are yyyy-mm-dd. Bounds are inclusive.

type BookingRow = { date?: string; attendance_status?: string; status?: string; client_id?: string };
type SetRow = { completed?: boolean; completedWeight?: number };
type ExerciseRow = { name?: string; sets?: SetRow[] };
type LogRow = { date?: string; exercises?: ExerciseRow[] };
type MeasureRow = {
  date?: string;
  weight?: string;
  chest?: string;
  waist?: string;
  hips?: string;
  arms?: string;
  thighs?: string;
};

export function inRange(date: string, from: string, to: string): boolean {
  return date >= from && date <= to;
}

export function leadingNumber(value: unknown): number | null {
  const match = String(value ?? "").match(/\d+(\.\d+)?/);
  if (!match) return null;
  const n = Number(match[0]);
  return Number.isFinite(n) ? n : null;
}

export function sessionsDone(rows: BookingRow[], from: string, to: string): number {
  return rows.filter((b) =>
    b.attendance_status === "checked-in" &&
    b.status !== "cancelled" &&
    typeof b.date === "string" &&
    inRange(b.date.slice(0, 10), from, to)
  ).length;
}

export function strengthGains(logs: LogRow[], from: string, to: string): { name: string; before: number; after: number }[] {
  const ordered = logs
    .filter((l) => typeof l.date === "string" && inRange(l.date.slice(0, 10), from, to))
    .sort((a, b) => String(a.date).localeCompare(String(b.date)));
  const first = new Map<string, number>();
  const last = new Map<string, number>();
  for (const log of ordered) {
    for (const ex of log.exercises || []) {
      const name = String(ex.name || "").trim();
      if (!name) continue;
      const weights = (ex.sets || [])
        .filter((s) => (s.completed || Number(s.completedWeight) > 0) && Number(s.completedWeight) > 0)
        .map((s) => Number(s.completedWeight));
      if (weights.length === 0) continue;
      const maxW = Math.max(...weights);
      if (!first.has(name)) first.set(name, maxW);
      last.set(name, maxW);
    }
  }
  const gains: { name: string; before: number; after: number }[] = [];
  for (const [name, before] of first) {
    const after = last.get(name) ?? before;
    if (after > before) gains.push({ name, before, after });
  }
  gains.sort((a, b) => (b.after - b.before) - (a.after - a.before));
  return gains;
}

const INCHES: { key: keyof MeasureRow; label: string }[] = [
  { key: "weight", label: "Weight" },
  { key: "chest", label: "Chest" },
  { key: "waist", label: "Waist" },
  { key: "hips", label: "Hips" },
  { key: "arms", label: "Arms" },
  { key: "thighs", label: "Thighs" },
];

export function bodyChanges(
  rows: MeasureRow[],
  from: string,
  to: string,
): { label: string; before: number; after: number }[] {
  const ordered = [...rows]
    .filter((m) => typeof m.date === "string")
    .sort((a, b) => String(a.date).localeCompare(String(b.date)));
  const inWindow = ordered.filter((m) => inRange(String(m.date).slice(0, 10), from, to));
  if (inWindow.length === 0) return [];
  const beforeWindow = ordered.filter((m) => String(m.date).slice(0, 10) < from);
  const out: { label: string; before: number; after: number }[] = [];
  for (const field of INCHES) {
    const read = (m: MeasureRow) => leadingNumber(m[field.key]);
    let newest: number | null = null;
    for (let i = inWindow.length - 1; i >= 0; i--) {
      const v = read(inWindow[i]);
      if (v != null) { newest = v; break; }
    }
    if (newest == null) continue;
    let oldest: number | null = null;
    for (const m of inWindow) {
      const v = read(m);
      if (v != null) { oldest = v; break; }
    }
    if (oldest == null || oldest === newest) {
      for (let i = beforeWindow.length - 1; i >= 0; i--) {
        const v = read(beforeWindow[i]);
        if (v != null) { oldest = v; break; }
      }
    }
    if (oldest == null || oldest === newest) continue;
    out.push({ label: field.label, before: oldest, after: newest });
  }
  return out;
}

export function num(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(1).replace(/\.0$/, "");
}
