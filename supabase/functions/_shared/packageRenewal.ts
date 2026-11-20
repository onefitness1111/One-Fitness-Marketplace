// Same rules as lib/core/utils/package_renewal.dart.
// The discount percent and the sessions-left threshold are the owner's
// package renewal offer in platform_settings.data.packageRenewal.
// When that object has never been saved: on, 5% off, starting at 8
// sessions left. Skip or dismiss forfeits that discount.
// 2 sessions left or fewer: full price, even when the discount is off.
// A package that still has every session, or one that was already
// renewed, is not offered. The percent is never taken from the client.

export const RENEW_DISCOUNT_AT = 8;
export const RENEW_FULL_AT = 2;
export const RENEW_PERCENT = 5;
export const RENEW_PERCENT_MIN = 1;
export const RENEW_PERCENT_MAX = 50;
export const RENEW_SESSIONS_MIN = 3;
export const RENEW_SESSIONS_MAX = 99;

export type RenewalOfferName = "none" | "discount" | "full";

export type RenewalOfferConfig = {
  enabled: boolean;
  percent: number;
  sessionsLeft: number;
};

export const DEFAULT_RENEWAL_OFFER: RenewalOfferConfig = {
  enabled: true,
  percent: RENEW_PERCENT,
  sessionsLeft: RENEW_DISCOUNT_AT,
};

function wholeInRange(value: unknown, min: number, max: number): number | null {
  if (typeof value !== "number" || !Number.isInteger(value)) return null;
  if (value < min || value > max) return null;
  return value;
}

/// Missing or out-of-range values become today's offer, so a row that
/// has never saved this setting charges the same price as before.
export function renewalOfferFromSettings(data: unknown): RenewalOfferConfig {
  const root = data && typeof data === "object" ? data as Record<string, unknown> : null;
  const raw = root?.packageRenewal;
  if (!raw || typeof raw !== "object") return { ...DEFAULT_RENEWAL_OFFER };
  const row = raw as Record<string, unknown>;
  return {
    enabled: typeof row.enabled === "boolean" ? row.enabled : true,
    percent: wholeInRange(row.percent, RENEW_PERCENT_MIN, RENEW_PERCENT_MAX) ?? RENEW_PERCENT,
    sessionsLeft: wholeInRange(row.sessionsLeft, RENEW_SESSIONS_MIN, RENEW_SESSIONS_MAX) ?? RENEW_DISCOUNT_AT,
  };
}

export function renewalDiscountCents(priceCents: number, percent = RENEW_PERCENT): number {
  if (priceCents <= 0) return 0;
  const rate = wholeInRange(percent, RENEW_PERCENT_MIN, RENEW_PERCENT_MAX) ?? RENEW_PERCENT;
  return Math.round((priceCents * rate) / 100);
}

export function renewalOffer(
  remaining: number,
  maxSessions: number,
  priceCents: number,
  forfeited: boolean,
  alreadyRenewed: boolean,
  config: RenewalOfferConfig = DEFAULT_RENEWAL_OFFER,
): RenewalOfferName {
  const settings = {
    enabled: config.enabled !== false,
    percent: wholeInRange(config.percent, RENEW_PERCENT_MIN, RENEW_PERCENT_MAX) ?? RENEW_PERCENT,
    sessionsLeft: wholeInRange(config.sessionsLeft, RENEW_SESSIONS_MIN, RENEW_SESSIONS_MAX) ?? RENEW_DISCOUNT_AT,
  };
  if (alreadyRenewed || priceCents <= 0 || maxSessions <= 0 || remaining >= maxSessions) return "none";
  if (remaining <= RENEW_FULL_AT) return "full";
  if (settings.enabled && remaining <= settings.sessionsLeft && !forfeited) return "discount";
  return "none";
}

/// Same sentences as renewalDiscountTitle / renewalDiscountBody in
/// lib/core/utils/package_renewal.dart.
export function renewalDiscountTitle(percent: number): string {
  return `Renew now at ${percent}% off`;
}

export function renewalDiscountBody(name: string, remaining: number, percent: number): string {
  return `Your ${name} has ${remaining} sessions left. Renew now and the price is ${percent}% off. If you skip this, that discount is gone for this package.`;
}

export function renewalIdempotencyKey(
  clientId: string,
  planId: string,
  enrollmentStart: string,
  offer: "discount" | "full",
  attempt = 1,
): string {
  const base = `pkg-renew-${clientId}-${planId}-${enrollmentStart}-${offer}`;
  return attempt <= 1 ? base : `${base}-${attempt}`;
}

export function effectivePackageMax(
  plan: { maxSessions?: number; kind?: string },
  override: number | null,
  overrideMonth: string | null,
  todayMonth: string,
): number {
  let base = Number(plan.maxSessions || 0);
  if (override != null && Number.isFinite(override)) {
    const stale = plan.kind === "membership" && !!overrideMonth && overrideMonth !== todayMonth;
    if (!stale) base = override;
  }
  return base;
}
