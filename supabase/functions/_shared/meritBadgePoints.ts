// 5 or more active Merit Badges (not sub-badges) keep a flat 5-point bonus.
// Fewer than 5 means that bonus is zero. Called after every award or removal.
// deno-lint-ignore no-explicit-any
type SupabaseClient = any;
import { replayLedger } from "./pointsLedger.ts";
import { GYM_CITIZEN_SUB_BADGE_KEYS } from "./gymCitizenSubBadges.ts";
import { PROGRESS_TRACKER_SUB_BADGE_KEYS } from "./progressTrackerSubBadges.ts";

const SUB_BADGE_KEYS = new Set([...GYM_CITIZEN_SUB_BADGE_KEYS, ...PROGRESS_TRACKER_SUB_BADGE_KEYS]);
const SIX_MONTHS_MS = 1000 * 60 * 60 * 24 * 30 * 6;
const MIN_ACTIVE_BADGES = 5;
const FLAT_BONUS_POINTS = 5;
const SOURCE = "merit_badge_points";

export async function syncMeritBadgePoints(admin: SupabaseClient, clientId: string) {
  const { data: badgeRows } = await admin.from("merit_badges").select("badge_key").eq("client_id", clientId).is("revoked_at", null);
  const activeCount = new Set(
    (badgeRows || []).map((r: { badge_key: string }) => r.badge_key).filter((k: string) => !SUB_BADGE_KEYS.has(k)),
  ).size;
  const target = activeCount >= MIN_ACTIVE_BADGES ? FLAT_BONUS_POINTS : 0;

  const { data: ledgerRows } = await admin.from("points_ledger").select("*").eq("client_id", clientId);
  const { lots } = replayLedger(ledgerRows || []);
  const meritLots = lots.filter((l) => l.source === SOURCE && l.remaining > 0);
  const current = meritLots.reduce((sum, l) => sum + l.remaining, 0);
  const delta = target - current;
  if (delta === 0) return;

  const nowIso = new Date().toISOString();
  if (delta > 0) {
    await admin.from("points_ledger").insert({
      client_id: clientId, amount: delta, type: "earn", source: SOURCE,
      earned_at: nowIso, expires_at: new Date(Date.now() + SIX_MONTHS_MS).toISOString(), created_at: nowIso,
    });
    return;
  }
  let toRemove = -delta;
  for (const lot of meritLots) {
    if (toRemove <= 0) break;
    const take = Math.min(lot.remaining, toRemove);
    if (take <= 0) continue;
    await admin.from("points_ledger").insert({
      client_id: clientId, amount: -take, type: "void", source: SOURCE,
      voided_by_ledger_id: lot.id, reason: "Active Merit Badge count decreased.", created_at: nowIso,
    });
    toRemove -= take;
  }
}
