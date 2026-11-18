// Push (and, when asked, email) for coach requests and applications.
// Best-effort: a missing device token or a mail failure must not undo the decision.
import { sendEmail } from "./sendEmail.ts";
import { sendPush } from "./sendPush.ts";

// deno-lint-ignore no-explicit-any
type Admin = any;

export async function notifyProfile(
  admin: Admin,
  profileId: string,
  title: string,
  body: string,
  alsoEmail: boolean,
): Promise<void> {
  if (!profileId) return;
  try {
    const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
    const tokens = (rows || []).map((r: { token: string }) => r.token).filter(Boolean);
    await sendPush(tokens, title, body);
  } catch (e) {
    console.error("request push failed:", e instanceof Error ? e.message : String(e));
  }
  if (!alsoEmail) return;
  try {
    const { data: profile } = await admin.from("profiles").select("email, name").eq("id", profileId).maybeSingle();
    const email = String(profile?.email ?? "").trim();
    if (email) await sendEmail(email, title, `${body}\n\n— ONE Fitness`);
  } catch (e) {
    console.error("request email failed:", e instanceof Error ? e.message : String(e));
  }
}

export async function pushOwners(admin: Admin, title: string, body: string): Promise<void> {
  const { data: owners } = await admin.from("profiles").select("id").eq("role", "owner");
  for (const owner of owners || []) {
    await notifyProfile(admin, owner.id as string, title, body, false);
  }
}

export async function emailOwners(admin: Admin, title: string, body: string, html?: string): Promise<void> {
  const { data: owners } = await admin.from("profiles").select("id, email").eq("role", "owner");
  for (const owner of owners || []) {
    const email = String(owner.email ?? "").trim();
    if (email) await sendEmail(email, title, `${body}\n\n— ONE Fitness`, html);
    await notifyProfile(admin, owner.id as string, title, body, false);
  }
}
