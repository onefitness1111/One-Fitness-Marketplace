// The only coach name a client may see. A blank coach name is "your coach".
// This never reads or builds a name from a legal first or last name.
export function coachDisplayName(coachName) {
  const chosen = String(coachName ?? "").trim();
  return chosen || "your coach";
}
