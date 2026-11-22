// `clients.plans` is the list of everything a client holds. membership_plan_id
// is only the primary slot. When that slot changes, the list changes with it.
// Packages and programs in the same list are left alone.
//
// Copied from the live change-membership-plan bundle so that function can
// be deployed from this repo. Not deployed by this change.

// deno-lint-ignore no-explicit-any
type Enrollment = Record<string, any>;

export function swapMembershipEnrollment(
  enrollments: unknown,
  outgoingPlanId: string | null | undefined,
  incomingPlanId: string,
  incomingTermMonths: number | null | undefined,
  subscriptionId?: string | null,
  outgoingUsableUntil?: string | null,
): Enrollment[] {
  const list: Enrollment[] = Array.isArray(enrollments) ? enrollments : [];
  const today = new Date().toISOString().slice(0, 10);
  return [
    ...list
      .filter((e) => e?.planId !== incomingPlanId)
      .map((e) =>
        outgoingPlanId && e?.planId === outgoingPlanId && e?.status === "active"
          ? (outgoingUsableUntil
            ? { ...e, endsAt: outgoingUsableUntil, subscriptionId: null }
            : { ...e, status: "cancelled" })
          : e,
      ),
    {
      planId: incomingPlanId,
      status: "active",
      startDate: today,
      termMonths: incomingTermMonths ?? null,
      ...(subscriptionId ? { subscriptionId } : {}),
    },
  ];
}

/// The client a Stripe subscription belongs to — whether it's their primary
/// (clients.stripe_subscription_id) or an additional membership held
/// alongside it (an entry in clients.plans carrying that subscriptionId).
// deno-lint-ignore no-explicit-any
export async function clientBySubscription(admin: any, subscriptionId: string, cols: string): Promise<Enrollment | null> {
  const { data } = await admin.from("clients").select(cols).eq("stripe_subscription_id", subscriptionId).maybeSingle();
  if (data) return data;
  const { data: rows } = await admin.from("clients").select(cols)
    .contains("plans", [{ subscriptionId }]).limit(1);
  return rows?.[0] ?? null;
}

/// After the primary slot is vacated, the next plan the client still holds
/// that should take it: an active membership first, else an active package.
/// Programs never hold the slot. Null when nothing is left.
// deno-lint-ignore no-explicit-any
export async function nextSlotHolder(admin: any, enrollments: Enrollment[]): Promise<Enrollment | null> {
  const active = enrollments.filter((e) => e?.status === "active" && e?.planId);
  if (active.length === 0) return null;
  const { data: rows } = await admin.from("membership_plans").select("id, data").in("id", active.map((e) => e.planId));
  const kindOf = new Map<string, string>((rows ?? []).map((r: Enrollment) => [r.id, r.data?.kind ?? "membership"]));
  return active.find((e) => kindOf.get(e.planId) === "membership")
    ?? active.find((e) => kindOf.get(e.planId) === "package")
    ?? null;
}
