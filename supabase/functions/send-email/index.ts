// Sends a real email as the ONE Fitness mailbox (info@onefitnessworkout.com).
//
// Proposed replacement. Not deployed until you deploy this function.
// The previous version let any signed-in person email any address.
//
// Now: the owner or a coach only. The recipient must be a member (pass
// profileId; an address is accepted only when it belongs to a member).
// A client cannot call this. There is a generous rate limit so a script
// cannot fire thousands of messages, without blocking a normal gym blast.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendEmailOrThrow } from "../_shared/sendEmail.ts";
import {
  CORS_HEADERS,
  assertStaffMayMessage,
  clip,
  enforceRateLimit,
  json,
  memberByEmail,
  memberById,
  requireStaff,
} from "../_shared/messagingGuard.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const body = await req.json();
    const subject = clip(body.subject, 200, "Subject");
    const text = clip(body.text, 8000, "Message");
    const { admin, userId, role } = await requireStaff(req);

    const profileId = String(body.profileId ?? "").trim();
    const to = String(body.to ?? "").trim();
    const member = profileId
      ? await memberById(admin, profileId)
      : await memberByEmail(admin, to);
    if (!member) throw new Error("That recipient isn't a member of ONE Fitness.");
    assertStaffMayMessage(role, member);
    if (!member.email) throw new Error("That member has no email address on file.");
    // If both were sent, the address has to be the member's. Stops a coach
    // who knows an outside address from swapping it in.
    if (to && to.toLowerCase() !== member.email.toLowerCase()) {
      throw new Error("That email address doesn't match the member.");
    }

    await enforceRateLimit(admin, userId, "email");
    await sendEmailOrThrow(member.email, subject, text);

    console.log(`send-email: ${userId} (${role}) -> ${member.id}`);
    return json({ ok: true });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-email failed:", message);
    const status = message.includes("Wait a few minutes") ? 429 : 400;
    return json({ error: message }, status);
  }
});
