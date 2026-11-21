// Owner-only in-app push: "Tap to get texts from your coach".
//
// Goes to clients whose sms_opt_in is false or null and who have not
// opted out. Which coach is assigned is not part of the decision.
//
// Push only. These people have not consented, so this function must not
// send an SMS and must not insert a chat message. A message whose channel
// includes SMS is texted by messages_auto_reply.
//
// Not deployed and not invoked by this change. After deploy, the owner
// taps "Ask clients about texts" on the home screen. Nothing here runs
// on a timer.
//   supabase functions deploy prompt-sms-opt-in
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendPush } from "../_shared/sendPush.ts";
import {
  type Admin,
  CORS_HEADERS,
  enforceRateLimit,
  json,
  requireStaff,
} from "../_shared/messagingGuard.ts";
import {
  SMS_OPT_IN_PUSH_BODY,
  SMS_OPT_IN_PUSH_TITLE,
  smsOptInPromptRecipients,
  smsOptInPushData,
} from "../_shared/smsOptInPrompt.ts";

type ProfileRow = { id?: string; sms_opted_out?: boolean };
type ClientRow = { profile_id?: string; sms_opt_in?: boolean | null };
type TokenRow = { token?: string };

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const { admin, userId, role } = await requireStaff(req);
    if (role !== "owner") throw new Error("Only the owner can ask clients about texts.");
    await enforceRateLimit(admin, userId, "push");

    const { data: profiles, error: profileError } = await admin
      .from("profiles")
      .select("id, sms_opted_out")
      .eq("role", "client")
      .is("deleted_at", null);
    if (profileError) throw new Error("Couldn't load clients.");

    const { data: clients, error: clientError } = await admin
      .from("clients")
      .select("profile_id, sms_opt_in");
    if (clientError) throw new Error("Couldn't load text preferences.");

    const ids = smsOptInPromptRecipients({
      profiles: ((profiles ?? []) as ProfileRow[]).map((row) => ({
        id: String(row.id ?? ""),
        smsOptedOut: row.sms_opted_out === true,
      })),
      clients: ((clients ?? []) as ClientRow[]).map((row) => ({
        profileId: String(row.profile_id ?? ""),
        smsOptIn: row.sms_opt_in === true ? true : row.sms_opt_in === false ? false : null,
      })),
    });

    if (ids.length === 0) return json({ ok: true, clients: 0, sent: 0 });

    const tokens = await deviceTokens(admin, ids);
    await sendPush(tokens, SMS_OPT_IN_PUSH_TITLE, SMS_OPT_IN_PUSH_BODY, smsOptInPushData());
    return json({ ok: true, clients: ids.length, sent: tokens.length });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("prompt-sms-opt-in failed:", message);
    const status = message.includes("Wait a few minutes") ? 429 : 400;
    return json({ error: message }, status);
  }
});

async function deviceTokens(admin: Admin, ids: string[]): Promise<string[]> {
  const tokens: string[] = [];
  for (let i = 0; i < ids.length; i += 80) {
    const slice = ids.slice(i, i + 80);
    const { data, error } = await admin.from("device_tokens").select("token").in("profile_id", slice);
    if (error) throw new Error("Couldn't load phones to notify.");
    for (const row of (data ?? []) as TokenRow[]) {
      const token = String(row.token ?? "").trim();
      if (token) tokens.push(token);
    }
  }
  return [...new Set(tokens)];
}
