// Plan visibility. Kept in step with lib/data/models/membership_plan.dart
// and with plan_visibility() in the plan-visibility migration.
//
// active  — clients can see it and buy it
// ghost   — clients cannot see it or buy it; staff can assign it and charge
//           for it; someone already on it keeps billing, sessions, rollover
// archived — closed to new sales, including staff assignment
//
// Rows saved before `status` existed only have `archived`.

export function planStatus(plan) {
  const raw = String(plan?.status ?? "").trim().toLowerCase();
  if (raw === "active" || raw === "ghost" || raw === "archived") return raw;
  if (plan?.archived === true) return "archived";
  return "active";
}

export function clientCatalogVisible(plan) {
  return planStatus(plan) === "active";
}

export function staffMayAssign(plan) {
  return planStatus(plan) !== "archived";
}

/**
 * Why a purchase must be refused, or null when it may go ahead.
 *
 * A client cannot start a purchase of a ghost or archived plan.
 * Staff enrolling a client may use a ghost plan.
 * A client renewing a package they already hold may pay, including when
 * that package is ghost — the renewal is the plan they already have, not
 * a new sale. Archived stays closed to new enrollment, staff included.
 */
export function purchaseBlockReason(plan, { staffEnrollingClient = false, renewingHeldPlan = false } = {}) {
  const status = planStatus(plan);
  if (status === "archived" && !renewingHeldPlan) {
    return "That plan is no longer available.";
  }
  if (status === "ghost" && !staffEnrollingClient && !renewingHeldPlan) {
    return "That plan isn't offered for purchase.";
  }
  return null;
}

export function assertPlanPurchasable(plan, opts = {}) {
  const reason = purchaseBlockReason(plan, opts);
  if (reason) throw new Error(reason);
}
