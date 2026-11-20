// Stripe coupon duration for a catalog code.
// One-time purchases never call this: a package is a single charge.

export function stripeCouponDuration(coupon) {
  const raw = String(coupon?.duration ?? "once");
  if (raw === "forever") return { duration: "forever" };
  if (raw === "repeating") {
    let months = Math.trunc(Number(coupon?.durationInMonths));
    if (!Number.isFinite(months) || months < 1) months = 1;
    if (months > 36) months = 36;
    return { duration: "repeating", duration_in_months: months };
  }
  return { duration: "once" };
}
