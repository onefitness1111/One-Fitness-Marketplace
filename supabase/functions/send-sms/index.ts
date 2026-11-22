// Sends one SMS on behalf of the owner or a coach.
//
// Proposed replacement. Not deployed until you deploy this function.
// The previous version let any signed-in person text any number.
//
// The number is looked up from the member's profile. A client cannot call
// this. Replies still land in app chat through the existing Twilio webhook.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { hasSmsConsent } from "../_shared/chatRouting.mjs";
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
    const text = clip(body.text, 1000, "Message");
    const profileId = String(body.profileId ?? "").trim();
    if (!profileId) throw new Error("Choose a member to text.");

    const { admin, userId, role } = await requireStaff(req);
    const member = await memberById(admin, profileId);
    if (!member) throw new Error("That recipient isn't a member of ONE Fitness.");
    assertStaffMayMessage(role, member);
    if (!member.phone) throw new Error("That member has no phone number on file.");

    const { data: gate } = await admin
      .from("profiles")
      .select("sms_opted_out, sms_consent_at")
      .eq("id", member.id)
      .maybeSingle();
    const { data: clientRow } = await admin
      .from("clients")
      .select("sms_opt_in, sms_declined_at")
      .eq("profile_id", member.id)
      .maybeSingle();
    const optedOut = gate?.sms_opted_out === true || clientRow?.sms_declined_at != null;
    // This function never sends the consent invite. No consent, a decline,
    // or an opt-out is an error, not a text. Invites are sent only by
    // chat-auto-reply-sms, and only when sms_invite_enabled is on, the
    // client has never been invited, sms_declined_at is null, and they
    // have not opted out.
    // Clients still need a consent record. A coach or the owner is textable
    // with a phone number unless they opted out.
    const consented = hasSmsConsent({
      role: member.role,
      smsConsentAt: gate?.sms_consent_at,
      smsOptIn: clientRow?.sms_opt_in === true,
    });
    if (optedOut) throw new Error("That person has opted out of text messages. The app chat still works.");
    if (!consented) throw new Error("That person hasn't agreed to text messages yet. The app chat still works.");

    const supplied = String(body.to ?? "").replace(/\D/g, "");
    const stored = member.phone.replace(/\D/g, "");
    if (supplied && !stored.endsWith(supplied.slice(-10)) && !supplied.endsWith(stored.slice(-10))) {
      throw new Error("That phone number doesn't match the member.");
    }

    const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
    const token = Deno.env.get("TWILIO_AUTH_TOKEN");
    const from = Deno.env.get("TWILIO_FROM_NUMBER");
    if (!sid || !token || !from) throw new Error("SMS isn't set up yet — the gym needs to add its Twilio details.");

    await enforceRateLimit(admin, userId, "sms");

    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ To: member.phone, From: from, Body: text }).toString(),
    });
    if (!res.ok) {
      const detail = await res.text();
      console.error(`send-sms: Twilio ${res.status}: ${detail}`);
      throw new Error("The SMS couldn't be sent — check the number and try again.");
    }

    console.log(`send-sms: ${userId} (${role}) -> ${member.id}`);
    return json({ ok: true });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-sms failed:", message);
    const status = message.includes("Wait a few minutes") ? 429 : 400;
    return json({ error: message }, status);
  }
});
