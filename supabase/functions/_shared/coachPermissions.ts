// Server-side check for the owner's per-coach permission switches.
//
// Call requireCoachPermission(admin, userId, role, "charge_fees") right
// after the caller is known to be staff. The owner always passes. A coach
// passes only when their own switch is on (table coach_permissions, read
// with the service role). Anyone else, or a coach with no row, is refused
// with a plain-English message. Never gate on primary_trainer_id.
import { permissionAllowed, permissionDeniedMessage } from "./coachPermissions.mjs";

export type CoachPermission =
  | "billing_access"
  | "charge_fees"
  | "edit_plans"
  | "send_texts"
  | "manage_other_schedules"
  | "see_own_revenue";

type Admin = {
  from: (table: string) => any;
};

export async function coachMay(
  admin: Admin,
  userId: string,
  role: string,
  permission: CoachPermission,
): Promise<boolean> {
  if (role === "owner") return permissionAllowed(role, null, permission);
  if (role !== "coach") return false;
  const { data, error } = await admin
    .from("coach_permissions")
    .select("billing_access, charge_fees, edit_plans, send_texts, manage_other_schedules, see_own_revenue")
    .eq("profile_id", userId)
    .maybeSingle();
  // If the table cannot be read, the answer is no, never "allowed".
  if (error) return false;
  return permissionAllowed(role, data ?? null, permission);
}

export async function requireCoachPermission(
  admin: Admin,
  userId: string,
  role: string,
  permission: CoachPermission,
): Promise<void> {
  if (!(await coachMay(admin, userId, role, permission))) {
    throw new Error(permissionDeniedMessage(permission));
  }
}
