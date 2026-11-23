// Push (and optional text) from the owner or a coach to a member.
//
// Proposed replacement. Not deployed until you deploy this function.
// The previous version let any signed-in person push or text any profile.
//
// profileId must be a member the caller is allowed to message. `sms: true`
// still texts only a client who opted in (see notifySms).
//
// A client caller (app 1.1.2 and later sends staff alerts this way) goes
// through handleClientPush: only alerts for the client's own real, recent
// booking, cancel, sign-up, measurement, or intake. The server picks the
// recipients and writes the words; the client's title is only a hint and
// their body, data, and sms flag are ignored. Notices to themself are a
// no-op (client-notify already sends those).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendPush } from "../_shared/sendPush.ts";
import { smsClientIfOptedIn } from "../_shared/notifySms.ts";
import {
  CORS_HEADERS,
  assertStaffMayMessage,
  clip,
  enforceRateLimit,
  json,
  memberById,
  adminClient,
  callerRole,
  callerUser,
} from "../_shared/messagingGuard.ts";
import { handleClientPush } from "../_shared/clientEventPush.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const body = await req.json();
    const profileId = String(body.profileId ?? "").trim();
    const title = clip(body.title, 120, "Title");
    const text = clip(body.body, 500, "Message");
    if (!profileId) throw new Error("profileId is required");

    const user = await callerUser(req);
    const userId = user.id;
    const admin = adminClient();
    const role = await callerRole(admin, userId);
    if (role === "client") {
      const result = await handleClientPush(admin, userId, body);
      if (!result.ok) console.warn("send-push: client alert skipped:", result.skipped);
      return json(result);
    }
    if (role !== "owner" && role !== "coach") {
      throw new Error("Only the owner or a coach can send that.");
    }
    const member = await memberById(admin, profileId);
    if (!member) throw new Error("That recipient isn't a member of ONE Fitness.");
    assertStaffMayMessage(role, member);

    await enforceRateLimit(admin, userId, "push");

    const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
    const tokens = (rows || []).map((r: { token: string }) => r.token as string);
    const data = body.data && typeof body.data === "object" ? body.data as Record<string, string> : undefined;
    await sendPush(tokens, title, text, data);

    let texted = false;
    if (body.sms === true && member.role === "client") {
      try {
        texted = await smsClientIfOptedIn(admin, profileId, `${title}. ${text}`);
      } catch (e) {
        console.error("send-push: SMS failed:", e instanceof Error ? e.message : String(e));
      }
    }
    return json({ ok: true, sent: tokens.length, texted });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-push failed:", message);
    const status = message.includes("Wait a few minutes") ? 429 : 400;
    return json({ error: message }, status);
  }
});
