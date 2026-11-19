// The only coach name a client may see. Callers pass trainers.coach_name or
// the result of coach_public_name. Never pass profiles.name.
import { coachDisplayName } from "./coachName.mjs";

export { coachDisplayName };

// deno-lint-ignore no-explicit-any
type Admin = any;

export async function publicCoachName(admin: Admin, id: string): Promise<string> {
  if (!id) return coachDisplayName(null);
  try {
    const { data, error } = await admin.rpc("coach_public_name", { p_id: id });
    const fromRpc = String(data ?? "").trim();
    if (!error && fromRpc) return coachDisplayName(fromRpc);
  } catch (_e) {
    // The column read below is the same rule when the function is missing.
  }
  const { data: trainer } = await admin.from("trainers")
    .select("coach_name")
    .eq("profile_id", id)
    .maybeSingle();
  return coachDisplayName(trainer?.coach_name);
}
