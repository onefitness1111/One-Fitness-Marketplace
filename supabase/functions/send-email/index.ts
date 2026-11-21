// Sends a real email as the ONE Fitness mailbox (info@onefitnessworkout.com).
//
// Proposed replacement. Not deployed until you deploy this function.
// The previous version let any signed-in person email any address.
//
// The owner or a coach can email a member. A client can email only a coach
// or the owner; the address is looked up here and is not returned.
// There is a generous rate limit so a script cannot fire thousands of messages.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendEmailOrThrow } from "../_shared/sendEmail.ts";
import {
  CORS_HEADERS,
  adminClient,
  assertStaffMayMessage,
  callerRole,
  callerUser,
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
    const profileId = String(body.profileId ?? "").trim();
    const to = String(body.to ?? "").trim();

    // A client may email their coach or the gym. The address is looked up
    // here and is never returned. Staff keep the broader sender.
    const user = await callerUser(req);
    const admin = adminClient();
    const caller = await callerRole(admin, user.id);
    if (caller === "client") {
      const member = await memberById(admin, profileId);
      if (!member || (member.role !== "coach" && member.role !== "owner")) {
        throw new Error("Clients can only email their coach or the gym.");
      }
      if (!member.email) throw new Error("That member has no email address on file.");
      await enforceRateLimit(admin, user.id, "email");
      await sendEmailOrThrow(member.email, subject, text);
      console.log(`send-email: ${user.id} (client) -> ${member.id}`);
      return json({ ok: true });
    }

    const { userId, role } = await requireStaff(req);
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
