// Notices a client is allowed to trigger. The wording is written here, not
// taken from the phone, except a chat message which is capped and can only
// push a coach or the owner — never email or SMS, and never an outside number.
//
// Proposed replacement. Not deployed until you deploy this function.
// Booking confirmations, the welcome ping, a goal reached, the coach's
// intake reminder, and an in-app chat alert use this instead of the open
// send-email / send-sms / send-push functions.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendPush } from "../_shared/sendPush.ts";
import { smsClientIfOptedIn } from "../_shared/notifySms.ts";
import { sendEmailOrThrow } from "../_shared/sendEmail.ts";
import {
  CORS_HEADERS,
  adminClient,
  callerRole,
  callerUser,
  clip,
  enforceRateLimit,
  json,
  memberById,
} from "../_shared/messagingGuard.ts";
import { pushStaffForClientMessage, resolveStaffAlertMessageId } from "../_shared/staffAlert.ts";
import { staffPushCopy } from "../_shared/chatRouting.mjs";

function cleanLabel(value: unknown, max: number): string {
  return String(value ?? "").trim().slice(0, max);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const body = await req.json();
    const kind = String(body.kind ?? "");
    const user = await callerUser(req);
    const admin = adminClient();
    const role = await callerRole(admin, user.id);
    if (role !== "client") throw new Error("That notice is sent from a client account.");

    const me = await memberById(admin, user.id);
    if (!me) throw new Error("Account not found.");

    await enforceRateLimit(admin, user.id, "client");

    const { data: tokenRows } = await admin.from("device_tokens").select("token").eq("profile_id", user.id);
    const myTokens = (tokenRows || []).map((r: { token: string }) => r.token);

    async function pushSelf(title: string, text: string, sms: boolean) {
      await sendPush(myTokens, title, text);
      if (sms) {
        try {
          await smsClientIfOptedIn(admin, user.id, `${title}. ${text}`);
        } catch (e) {
          console.error("client-notify sms:", e instanceof Error ? e.message : String(e));
        }
      }
    }

    if (kind === "booking-confirmed" || kind === "rescheduled") {
      const when = cleanLabel(body.when, 80);
      if (!when) throw new Error("Missing the session time.");
      const title = kind === "rescheduled" ? "Session rescheduled" : "Booking confirmed";
      const text = kind === "rescheduled"
        ? `Your session is now ${when}.`
        : `You're booked for ${when}.`;
      await pushSelf(title, text, true);
      return json({ ok: true });
    }

    if (kind === "low-sessions") {
      const remaining = Number(body.remaining);
      if (remaining !== 1 && remaining !== 2) throw new Error("Nothing to send.");
      const text = `You have ${remaining} session${remaining === 1 ? "" : "s"} left this period.`;
      await pushSelf("Low session balance", text, true);
      return json({ ok: true });
    }

    if (kind === "welcome") {
      await pushSelf(
        "Welcome to ONE Fitness",
        "Your account is set up. You'll get booking confirmations, reminders and waitlist offers here. Reply STOP to opt out.",
        true,
      );
      return json({ ok: true });
    }

    if (kind === "goal-reached") {
      const title = "Goal reached!";
      const text = "Your latest measurement shows you've reached your goal weight. Amazing work!";
      await pushSelf(title, text, false);
      if (me.email) {
        try {
          await sendEmailOrThrow(
            me.email,
            "You reached your goal weight!",
            `Hi ${me.name || "there"},\n\nCongratulations — your latest measurement shows you've reached your goal weight. Amazing work!\n\n— ONE Fitness`,
          );
        } catch (e) {
          console.error("client-notify goal email:", e instanceof Error ? e.message : String(e));
        }
      }
      return json({ ok: true });
    }

    if (kind === "intake-gap") {
      const trainerId = String(body.trainerId ?? "").trim();
      const coach = await memberById(admin, trainerId);
      if (!coach || coach.role !== "coach") throw new Error("That coach isn't on the roster.");
      const titles = Array.isArray(body.missingTitles)
        ? body.missingTitles.map((t: unknown) => cleanLabel(t, 80)).filter(Boolean).slice(0, 6)
        : [];
      if (titles.length === 0) return json({ ok: true, skipped: true });
      const sessionDate = cleanLabel(body.sessionDate, 40) || "an upcoming session";
      const what = titles.length === 1 ? titles[0] : `${titles.length} intake forms`;
      const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", trainerId);
      const tokens = (rows || []).map((r: { token: string }) => r.token);
      await sendPush(
        tokens,
        "Incomplete intake",
        `${me.name || "A client"} booked ${sessionDate} and hasn't finished ${what}.`,
        { type: "incomplete-intake" },
      );
      return json({ ok: true });
    }

    if (kind === "chat-to-staff") {
      const profileId = String(body.profileId ?? "").trim();
      const staff = await memberById(admin, profileId);
      if (!staff || (staff.role !== "coach" && staff.role !== "owner")) {
        throw new Error("Clients can only alert their coach or the gym in the app.");
      }
      const text = clip(body.body, 500, "Message");
      const messageId = await resolveStaffAlertMessageId(admin, {
        explicitId: String(body.messageId ?? ""),
        senderId: user.id,
        staffId: profileId,
        staffRole: staff.role,
        body: text,
      });
      if (messageId) {
        const outcome = await pushStaffForClientMessage(admin, {
          messageId,
          staffId: profileId,
          clientName: me.name,
          body: text,
        });
        if (outcome === "skipped") return json({ ok: true, skipped: "already pushed" });
        return json({ ok: true });
      }
      const copy = staffPushCopy(me.name, text);
      const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", profileId);
      const tokens = (rows || []).map((r: { token: string }) => r.token);
      await sendPush(tokens, copy.title, copy.body);
      return json({ ok: true });
    }

    throw new Error("Unknown notice.");
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("client-notify failed:", message);
    const status = message.includes("Wait a few minutes") ? 429 : 400;
    return json({ error: message }, status);
  }
});
