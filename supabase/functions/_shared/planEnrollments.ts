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
