// Pure rules for the owner's per-coach permission switches. The server
// functions import this through coachPermissions.ts, and the tests run it
// directly. The database holds the same six names in coach_permissions.
//
// The owner always may. A coach may only when their own switch is on. Anyone
// else (a client, no role) may not. A missing row is "off".

export const COACH_PERMISSIONS = [
  "billing_access",
  "charge_fees",
  "edit_plans",
  "send_texts",
  "manage_other_schedules",
  "see_own_revenue",
];

const DENIED = {
  billing_access: "You don't have billing and payments access. Ask the owner to turn it on.",
  charge_fees: "You don't have permission to charge fees. Ask the owner to turn it on.",
  edit_plans: "You don't have permission to edit plans and memberships. Ask the owner to turn it on.",
  send_texts: "You don't have permission to text clients. In-app messages still work. Ask the owner to turn it on.",
  manage_other_schedules: "You don't have permission to book onto another coach's schedule. Ask the owner to turn it on.",
  see_own_revenue: "You don't have permission to see revenue. Ask the owner to turn it on.",
};

export function isCoachPermission(name) {
  return COACH_PERMISSIONS.includes(name);
}

/** The plain-English refusal shown to the coach. */
export function permissionDeniedMessage(permission) {
  return DENIED[permission] ?? "You don't have permission to do that. Ask the owner.";
}

/**
 * role: 'owner' | 'coach' | other. row: the coach_permissions row or null.
 * Unknown permission names are never allowed, not even for the owner, so a
 * typo in a call site fails closed instead of silently passing.
 */
export function permissionAllowed(role, row, permission) {
  if (!isCoachPermission(permission)) return false;
  if (role === "owner") return true;
  if (role !== "coach") return false;
  return row != null && row[permission] === true;
}
