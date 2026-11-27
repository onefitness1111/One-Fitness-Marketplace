// Confirms to a client that they're on the waitlist.
//
// Joining a waitlist previously sent nothing at all: push, SMS and email
// were only ever wired into offer-waitlist-slot, which fires when a spot
// actually frees up. So a client tapped "Join waitlist", saw a row appear
// in the app, and got no message — which reads as the request not having
// gone through.
//
// Runs server-side rather than from the app because the client's own phone
// number and notification preferences are on rows the app shouldn't have to
// read, and because SMS credentials never belong on a device.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendPush } from "../_shared/sendPush.ts";
import { sendEmail } from "../_shared/sendEmail.ts";
import { sendSms } from "../_shared/sendSms.ts";
import { EMAIL_SIGNOFF, SMS_PREFIX } from "../_shared/businessName.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });

function fmtSlot(minutes: number): string {
  const h24 = Math.floor(minutes / 60);
  const m = minutes % 60;
  const h = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${h}:${String(m).padStart(2, "0")} ${h24 < 12 ? "AM" : "PM"}`;
}

/// "Mon 6 Oct" — enough to be unambiguous without being a wall of text in
/// an SMS.
function fmtDate(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return iso;
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${days[d.getUTCDay()]} ${d.getUTCDate()} ${months[d.getUTCMonth()]}`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    // The client is always the caller — never an id from the body, so this
    // can't be used to spam someone else's phone.
    const authed = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) return json({ error: "Not signed in." }, 401);

    const { date, slot, position } = await req.json();
    if (!date || slot === undefined || slot === null) {
      return json({ error: "date and slot are required" }, 400);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: profile } = await admin
      .from("profiles")
      .select("email, name, phone, sms_opted_out")
      .eq("id", user.id)
      .maybeSingle();
    const { data: prefs } = await admin
      .from("clients")
      .select("sms_opt_in")
      .eq("profile_id", user.id)
      .maybeSingle();

    const when = `${fmtDate(String(date))} at ${fmtSlot(Number(slot))}`;
    const place = position ? ` You're number ${position} in line.` : "";
    const title = "You're on the waitlist";
    const body = `You're on the waitlist for ${when}.${place} We'll message you the moment a spot opens up.`;

    const sent: string[] = [];

    // Push — always, it's the channel they opted into by installing the app.
    try {
      const { data: tokens } = await admin
        .from("device_tokens")
        .select("token")
        .eq("profile_id", user.id);
      const list = (tokens || []).map((t: { token: string }) => t.token);
      if (list.length > 0) {
        await sendPush(list, title, body);
        sent.push("push");
      }
    } catch (e) {
      console.error("waitlist join push failed:", e);
    }

    // SMS — only with a number on file AND an explicit opt-in (TCPA). A
    // client who never answered (sms_opt_in null) or replied STOP is not
    // texted. Phone is optional at signup, so "no number" is normal.
    try {
      const phone = String(profile?.phone ?? "").trim();
      const optedIn = prefs?.sms_opt_in === true && profile?.sms_opted_out !== true;
      if (phone && optedIn) {
        await sendSms(phone, `${SMS_PREFIX}${body}`);
        sent.push("sms");
      }
    } catch (e) {
      console.error("waitlist join sms failed:", e);
    }

    try {
      if (profile?.email) {
        await sendEmail(
          profile.email,
          title,
          `Hi ${profile.name ?? ""},\n\n${body}\n\n${EMAIL_SIGNOFF}`,
        );
        sent.push("email");
      }
    } catch (e) {
      console.error("waitlist join email failed:", e);
    }

    console.log(`notify-waitlist-joined: ${user.id} ${when} -> ${sent.join(", ") || "nothing"}`);
    return json({ ok: true, sent });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("notify-waitlist-joined failed:", message);
    return json({ error: message }, 400);
  }
});
