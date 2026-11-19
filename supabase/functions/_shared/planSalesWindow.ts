// Unchanged copy of the live helper.
// deno-lint-ignore no-explicit-any
type AnyPlan = any;

export function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

export function planOnSale(plan: AnyPlan, today: string = todayIso()): boolean {
  const from = String(plan?.startDate ?? "").trim();
  if (from && today < from) return false;
  const until = String(plan?.endDate ?? "").trim();
  if (until && today > until) return false;
  return true;
}

export function assertPlanOnSale(plan: AnyPlan): void {
  const today = todayIso();
  const from = String(plan?.startDate ?? "").trim();
  if (from && today < from) {
    throw new Error(`This plan goes on sale on ${from}.`);
  }
  const until = String(plan?.endDate ?? "").trim();
  if (until && today > until) {
    throw new Error("This plan is no longer available.");
  }
}
