// Push (and optional text) from the owner or a coach to a member.
//
// Proposed replacement. Not deployed until you deploy this function.
// The previous version let any signed-in person push or text any profile.
//
// profileId must be a member the caller is allowed to message. `sms: true`
// still texts only a client who opted in (see notifySms). A client cannot
// call this; their own booking notices go through client-notify.
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
  requireStaff,
} from "../_shared/messagingGuard.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const body = await req.json();
    const profileId = String(body.profileId ?? "").trim();
    const title = clip(body.title, 120, "Title");
    const text = clip(body.body, 500, "Message");
    if (!profileId) throw new Error("profileId is required");

    const { admin, userId, role } = await requireStaff(req);
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
