// Billing-day math for a new monthly membership.
//
// The anchor is 12:00 AM America/Los_Angeles on the billing day, including
// across daylight saving. Buying before that day this month pays through
// this month's anchor. Buying on that day or after pays through next month's.
// Buying on the anchor day itself is a full cycle, and the next charge is
// the following anchor.

import { wallTimeToUtc } from "./calendarFeed.mjs";

export const BILLING_TIME_ZONE = "America/Los_Angeles";

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

export function clampAnchorDay(day) {
  const n = Math.trunc(Number(day));
  if (!Number.isFinite(n) || n < 1) return null;
  return Math.min(28, n);
}

function zoneDate(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date).reduce((acc, part) => {
    if (part.type !== "literal") acc[part.type] = part.value;
    return acc;
  }, {});
  return { year: Number(parts.year), month: Number(parts.month), day: Number(parts.day) };
}

function shiftMonth(year, month, delta) {
  const index = year * 12 + (month - 1) + delta;
  return { year: Math.floor(index / 12), month: (index % 12) + 1 };
}

function iso(year, month, day) {
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

export function money(cents) {
  const n = Math.round(Number(cents) || 0);
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  return `${sign}$${(abs / 100).toFixed(2)}`;
}

export function prettyDate(isoDate) {
  const [year, month, day] = String(isoDate).split("-").map(Number);
  return `${MONTHS[month - 1]} ${day}, ${year}`;
}

/// Null when there is no anchor day or nothing to charge.
export function membershipFirstCharge(now, priceCents, anchorDay, timeZone = BILLING_TIME_ZONE) {
  const day = clampAnchorDay(anchorDay);
  const price = Math.max(0, Math.round(Number(priceCents) || 0));
  if (!day || price <= 0) return null;

  const today = zoneDate(now, timeZone);
  const nextMonth = today.day < day ? { year: today.year, month: today.month } : shiftMonth(today.year, today.month, 1);
  const prevMonth = shiftMonth(nextMonth.year, nextMonth.month, -1);
  const nextAt = wallTimeToUtc(iso(nextMonth.year, nextMonth.month, day), 0, timeZone);
  const prevAt = wallTimeToUtc(iso(prevMonth.year, prevMonth.month, day), 0, timeZone);
  const startAt = wallTimeToUtc(iso(today.year, today.month, today.day), 0, timeZone);
  const cycleMs = nextAt.getTime() - prevAt.getTime();
  const remainingMs = nextAt.getTime() - startAt.getTime();
  const proratedCents = cycleMs <= 0 || remainingMs === cycleMs
    ? price
    : Math.round((price * remainingMs) / cycleMs);

  return {
    proratedCents,
    fullCents: price,
    fullMonth: proratedCents === price,
    nextChargeAt: nextAt.toISOString(),
    nextChargeUnix: Math.floor(nextAt.getTime() / 1000),
    nextChargeDate: iso(nextMonth.year, nextMonth.month, day),
    anchorDay: day,
  };
}

export function discountCents(priceCents, coupon) {
  const price = Math.max(0, Math.round(Number(priceCents) || 0));
  if (!coupon || price <= 0) return 0;
  if (coupon.type === "flat") return Math.min(Math.round(Number(coupon.flatOffCents) || 0), price);
  const percent = Math.min(100, Math.max(0, Math.round(Number(coupon.percentOff) || 0)));
  return Math.round((price * percent) / 100);
}

/// Discount that still applies on the invoice after the first one.
export function ongoingDiscountCents(fullCents, coupon) {
  if (!coupon) return 0;
  const duration = coupon.duration || "once";
  if (duration === "once") return 0;
  if (duration === "repeating") {
    const months = Math.max(1, Math.round(Number(coupon.durationInMonths) || 1));
    if (months <= 1) return 0;
  }
  return discountCents(fullCents, coupon);
}

/// Plan amount on the first invoice. Normally the prorated amount. When the
/// owner turns on "Charge full price now", it is the full price instead, and
/// the next charge is still the next anchor.
export function firstChargePlanCents(quote, options = {}) {
  if (!quote) return 0;
  return options.fullFirstCharge ? quote.fullCents : quote.proratedCents;
}

export function firstChargeSentence(quote, coupon, options = {}) {
  if (!quote) return "";
  const full = !!options.fullFirstCharge;
  const base = firstChargePlanCents(quote, { fullFirstCharge: full });
  const when = prettyDate(quote.nextChargeDate);
  const off = discountCents(base, coupon);
  const today = base - off;
  const laterOff = ongoingDiscountCents(quote.fullCents, coupon);
  const later = quote.fullCents - laterOff;
  const todayWords = quote.fullMonth
    ? `Today ${money(today)}, a full month`
    : full
    ? `Today ${money(today)}, full price`
    : `Today ${money(today)}, prorated through ${when}`;
  const couponWords = coupon ? ` (${couponPhrase(coupon, base)})` : "";
  const nextLabel = laterOff > 0 ? "Next charge" : "Next full charge";
  return `${todayWords}${couponWords}. ${nextLabel} ${money(later)} on ${when}.`;
}

export function couponPhrase(coupon, baseCents) {
  const amount = coupon.type === "flat"
    ? `${money(Math.min(Math.round(Number(coupon.flatOffCents) || 0), baseCents ?? coupon.flatOffCents))} off`
    : `${Math.round(Number(coupon.percentOff) || 0)}% off`;
  const duration = coupon.duration || "once";
  if (duration === "forever") return `${amount} every month`;
  if (duration === "repeating") {
    const months = Math.max(1, Math.round(Number(coupon.durationInMonths) || 1));
    return `${amount} for ${months} month${months === 1 ? "" : "s"}`;
  }
  return `${amount}, first payment only`;
}
