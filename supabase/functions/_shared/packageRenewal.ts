// Same numbers as lib/core/utils/package_renewal.dart.
// 8 sessions left: 5% off. Skip or dismiss forfeits that discount.
// 2 sessions left or fewer: full price. A package that still has every
// session, or one that was already renewed, is not offered.

export const RENEW_DISCOUNT_AT = 8;
export const RENEW_FULL_AT = 2;
export const RENEW_PERCENT = 5;

export type RenewalOfferName = "none" | "discount" | "full";

export function renewalDiscountCents(priceCents: number): number {
  if (priceCents <= 0) return 0;
  return Math.round((priceCents * RENEW_PERCENT) / 100);
}

export function renewalOffer(
  remaining: number,
  maxSessions: number,
  priceCents: number,
  forfeited: boolean,
  alreadyRenewed: boolean,
): RenewalOfferName {
  if (alreadyRenewed || priceCents <= 0 || maxSessions <= 0 || remaining >= maxSessions) return "none";
  if (remaining <= RENEW_FULL_AT) return "full";
  if (remaining <= RENEW_DISCOUNT_AT && !forfeited) return "discount";
  return "none";
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
