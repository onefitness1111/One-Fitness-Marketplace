// One confirmation email per booking action.
//
//   { bookingIds: string[] }  -> the sessions the client just booked in ONE
//                                checkout/submit. Sent as ONE email listing all
//                                of them. Two separate submits = two emails.
//
// Never a duplicate: each booking is "claimed" by stamping
// bookings.confirmation_emailed_at only where it is still null, and only the
// bookings that claim succeeded for are listed. A booking already confirmed is
// silently left out, and if none remain nothing is sent. If the send itself
// fails the claim is released so a retry can still deliver it.
//
// Sent from the ONE Fitness mailbox (info@onefitnessworkout.com, via the shared
// Microsoft Graph sender) using the template below.
import { coachDisplayName } from "../_shared/coachName.ts";
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendHtmlEmailOrThrow } from "../_shared/sendEmail.ts";
import { businessName, loadTemplate, renderEmail } from "../_shared/emailTemplates.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

function timeLabel(slotMin: number): string {
  const h24 = Math.floor(slotMin / 60);
  const m = slotMin % 60;
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${h12}:${String(m).padStart(2, "0")} ${h24 >= 12 ? "PM" : "AM"}`;
}
function dateLabel(iso: string): string {
  const d = new Date(iso + "T12:00:00Z");
  return d.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC" });
}
function typeLabel(t: string): string {
  const v = (t || "").toLowerCase();
  if (v.includes("semi")) return "Semi-private";
  if (v.includes("one") || v.includes("personal") || v.includes("private")) return "One-on-one";
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : "Session";
}
function locationName(raw: unknown): string {
  if (typeof raw === "string" && raw.trim()) return raw;
  if (raw && typeof raw === "object") {
    const n = raw as { name?: string; address?: string };
    return n.name || n.address || "";
  }
  return "";
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  const claimed: string[] = [];
  const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  try {
    const { bookingIds } = await req.json();
    if (!Array.isArray(bookingIds) || bookingIds.length === 0) throw new Error("bookingIds is required");
    const ids = [...new Set(bookingIds.map(String))].slice(0, 100);

    const authed = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const { data: rows, error: loadErr } = await admin.from("bookings")
      .select("id, client_id")
      .in("id", ids);
    if (loadErr) throw loadErr;
    if (!rows || rows.length === 0) return json({ sent: false, reason: "no bookings" });

    // The recipient is the booking's client. Only that client (or staff) may
    // trigger it, and every booking in one call must belong to one client.
    const clientId = rows[0].client_id as string;
    if (rows.some((r) => r.client_id !== clientId)) throw new Error("Bookings must all belong to one client.");
    if (user.id !== clientId) {
      const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (me?.role !== "owner" && me?.role !== "coach") throw new Error("Not allowed.");
    }

    // The owner can switch this automation off (Customize Platform).
    const template = await loadTemplate(admin, "booking_confirmation");
    if (!template || !template.enabled) return json({ sent: false, reason: "disabled" });

    // Claim: only bookings still unconfirmed are stamped (and listed).
    const { data: won, error: claimErr } = await admin.from("bookings")
      .update({ confirmation_emailed_at: new Date().toISOString() })
      .in("id", rows.map((r) => r.id))
      .is("confirmation_emailed_at", null)
      .select("id, trainer_id, date, slot_min, session_type, location");
    if (claimErr) throw claimErr;
    if (!won || won.length === 0) return json({ sent: false, reason: "already confirmed" });
    claimed.push(...won.map((w) => w.id as string));

    const { data: client } = await admin.from("profiles").select("name, email").eq("id", clientId).maybeSingle();
    if (!client?.email) throw new Error("This client has no email address on file.");

    const trainerIds = [...new Set(won.map((w) => w.trainer_id as string))];
    const { data: coaches } = await admin.from("profiles").select("id, name").in("id", trainerIds);
    const coachName = (id: string) => coachDisplayName((coaches ?? []).find((c) => c.id === id)?.name);

    const sessions = [...won]
      .sort((a, b) => `${a.date}${String(a.slot_min).padStart(5, "0")}`.localeCompare(`${b.date}${String(b.slot_min).padStart(5, "0")}`))
      .map((w) => ({
        session_date: dateLabel(String(w.date)),
        session_time: timeLabel(Number(w.slot_min)),
        coach_name: coachName(w.trainer_id as string),
        session_type: typeLabel(String(w.session_type)),
        session_location: locationName(w.location) || "See the app for the location",
      }));

    const firstName = ((client.name as string) || "there").trim().split(/\s+/)[0];
    const count = sessions.length;
    const business = await businessName(admin);
    const { subject, html } = renderEmail({
      template,
      business,
      sessions,
      vars: {
        client_first_name: firstName,
        business_name: business,
        session_count: `${count} session${count === 1 ? "" : "s"}`,
      },
    });

    await sendHtmlEmailOrThrow(client.email as string, subject, html);
    console.log(`send-booking-confirmation: ${count} session(s) -> ${client.email}`);
    return json({ sent: true, sessions: count });
  } catch (e) {
    // Release the claim so a retry can still deliver these sessions.
    if (claimed.length) {
      await admin.from("bookings").update({ confirmation_emailed_at: null }).in("id", claimed);
    }
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-booking-confirmation failed:", message);
    return json({ error: message }, 400);
  }
});
