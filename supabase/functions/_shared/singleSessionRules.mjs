// Decisions for a one-off session. The price and the Allowed flag always come
// from platform settings. The phone never supplies the amount.

export function priceFromSettings(entry) {
  const priceCents = Math.round(Number(entry?.priceCents ?? 0));
  const allowed = entry?.allowed === true && priceCents > 0;
  return { allowed, priceCents };
}

export function money(cents) {
  const n = Math.abs(Number(cents) || 0);
  return `$${(n / 100).toFixed(2)}`;
}

// One card charge: the session price plus whatever they already owe.
// A negative balance is included. A credit (positive balance) is not.
export function singleSessionTotal(sessionCents, balanceCents) {
  const session = Math.max(0, Math.round(Number(sessionCents) || 0));
  const balance = Number(balanceCents) < 0 ? -Math.round(Number(balanceCents)) : 0;
  return { sessionCents: session, balanceCents: balance, totalCents: session + balance };
}

export function singleSessionBreakdown(bill) {
  if (!bill || bill.balanceCents <= 0) return "";
  return `Session ${money(bill.sessionCents)} + balance ${money(bill.balanceCents)} = total ${money(bill.totalCents)}`;
}

// The balance is settled only after the seat is booked. A full session
// refunds the entire charge and leaves the balance alone.
export function afterSingleSessionPayment(booked) {
  return booked
    ? { settleBalance: true, refundWholeCharge: false }
    : { settleBalance: false, refundWholeCharge: true };
}

// Free adds only. A paid single session is not a grace booking.
// Owner: any number of free adds. Coach: one while the balance is unpaid.
export function staffMayAddSingle({ role, balanceCents, graceUsed }) {
  const owes = Number(balanceCents ?? 0) < 0;
  if (!owes) return { ok: true, consumeGrace: false };
  if (role === "owner") return { ok: true, consumeGrace: false };
  if (role === "coach" && graceUsed !== true) return { ok: true, consumeGrace: true };
  return {
    ok: false,
    consumeGrace: false,
    code: "BALANCE_GRACE_USED",
    message: `This client has an outstanding balance of ${money(balanceCents)}.`,
  };
}

// A coach's one free add per week. The owner is not limited.
export function coachFreeAddBlocked({ role, usedThisWeek }) {
  if (role === "owner") return false;
  return Number(usedThisWeek ?? 0) >= 1;
}

export const FREE_ADD_LIMIT_MESSAGE =
  "This coach already used the one free session add for this week. Ask the owner to approve another.";

// Monday 00:00 America/Los_Angeles through the next Monday, matching
// date_trunc('week', timezone('America/Los_Angeles', now())).
export function pacificWeekRange(now = new Date()) {
  const zone = "America/Los_Angeles";
  const bag = (date, timeZone) => {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      weekday: "short",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).formatToParts(date);
    const out = {};
    for (const part of parts) out[part.type] = part.value;
    if (out.hour === "24") out.hour = "00";
    return out;
  };
  const wall = bag(now, zone);
  const weekday = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 }[wall.weekday] ?? 1;
  const sinceMonday = (weekday + 6) % 7;
  const asUtc = Date.UTC(
    Number(wall.year),
    Number(wall.month) - 1,
    Number(wall.day),
    Number(wall.hour),
    Number(wall.minute),
    Number(wall.second),
  );
  const offset = asUtc - now.getTime();
  const todayStart = Date.UTC(Number(wall.year), Number(wall.month) - 1, Number(wall.day)) - offset;
  const start = todayStart - sinceMonday * 86400000;
  return { start: new Date(start).toISOString(), end: new Date(start + 7 * 86400000).toISOString() };
}
