// How a coach is named to clients: "Coach {first name}", never the legal name.
// Staff-facing screens (payroll, records) keep the full name.
export function coachDisplayName(fullName: string | null | undefined): string {
  const first = String(fullName ?? "").trim().split(/\s+/)[0];
  return first ? `Coach ${first}` : "Your coach";
}
