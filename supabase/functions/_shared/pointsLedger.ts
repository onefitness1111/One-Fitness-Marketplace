// Unchanged copy of the live points helper used by create-payment-intent.
// deno-lint-ignore no-explicit-any
export type LedgerRow = any;

export interface Lot {
  id: string;
  source: string;
  remaining: number;
  expires_at: string | null;
}

const toMs = (d: string | Date) => (d instanceof Date ? d.getTime() : new Date(d).getTime());

export function replayLedger(rows: LedgerRow[], now: Date = new Date()) {
  const nowMs = now.getTime();
  const sorted = [...(rows || [])].sort((a, b) => {
    const ta = toMs(a.created_at), tb = toMs(b.created_at);
    return ta !== tb ? ta - tb : String(a.id).localeCompare(String(b.id));
  });

  const lotsById = new Map<string, Lot>();
  const lotsOrder: string[] = [];

  const consumeFifo = (amountToConsume: number) => {
    let left = amountToConsume;
    for (const lotId of lotsOrder) {
      if (left <= 0) break;
      const lot = lotsById.get(lotId)!;
      if (lot.remaining <= 0) continue;
      const take = Math.min(lot.remaining, left);
      lot.remaining -= take;
      left -= take;
    }
  };

  for (const row of sorted) {
    if (row.type === "earn" || row.type === "grant") {
      const lot: Lot = { id: row.id, source: row.source, remaining: row.amount, expires_at: row.expires_at };
      lotsById.set(row.id, lot);
      lotsOrder.push(row.id);
    } else if (row.type === "void" || row.type === "expire") {
      const lot = lotsById.get(row.voided_by_ledger_id);
      if (lot) lot.remaining = Math.max(0, lot.remaining - Math.abs(row.amount));
    } else if (row.type === "redeem" || row.type === "deduct") {
      consumeFifo(Math.abs(row.amount));
    }
  }

  const lots = lotsOrder.map((id) => lotsById.get(id)!);
  const isLive = (lot: Lot) => lot.remaining > 0 && (!lot.expires_at || toMs(lot.expires_at) > nowMs);
  const balance = lots.reduce((sum, lot) => (isLive(lot) ? sum + lot.remaining : sum), 0);
  const pendingExpiry = lots.filter((lot) => lot.remaining > 0 && lot.expires_at && toMs(lot.expires_at) <= nowMs);
  return { lots, balance, pendingExpiry };
}

export function planRedemption(
  lots: Lot[],
  now: Date = new Date(),
  { capPoints = 40, minPoints = 40 }: { capPoints?: number; minPoints?: number } = {},
) {
  const nowMs = now.getTime();
  const active = lots.filter((lot) => lot.remaining > 0 && (!lot.expires_at || toMs(lot.expires_at) > nowMs));
  const balance = active.reduce((s, l) => s + l.remaining, 0);
  if (balance < minPoints) return null;
  const points = Math.min(balance, capPoints);
  let left = points;
  const allocations: { lotId: string; amount: number }[] = [];
  for (const lot of active) {
    if (left <= 0) break;
    const take = Math.min(lot.remaining, left);
    if (take > 0) {
      allocations.push({ lotId: lot.id, amount: take });
      left -= take;
    }
  }
  return { points, allocations };
}

export function pointsToDiscountCents(points: number, subtotalCents: number, rateBp = 50): number {
  return Math.round((subtotalCents * points * rateBp) / 10000);
}
