// Push and email when a Merit Badge is earned. A missing token or a mail
// failure must not undo the award.
import { notifyProfile } from "./requestNotify.ts";
import { BADGE_NAMES } from "./badgeRules.mjs";

// deno-lint-ignore no-explicit-any
type Admin = any;

export async function notifyBadgeEarned(admin: Admin, clientId: string, badgeKey: string): Promise<void> {
  const name = (BADGE_NAMES as Record<string, string>)[badgeKey];
  if (!name || !clientId) return;
  await notifyProfile(
    admin,
    clientId,
    "Merit Badge earned!",
    `You earned the ${name} badge. Open the app to see it.`,
    true,
  );
}
