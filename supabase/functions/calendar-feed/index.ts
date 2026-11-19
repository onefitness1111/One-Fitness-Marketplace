// Serves one person's sessions as an iCalendar feed. Google, Apple, and
// Outlook fetch this URL with no login, so the gateway must not require a
// JWT. The unguessable token is the access check. Regenerating it in
// get-calendar-link makes the old URL 404.
//
// A client sees the sessions they booked. A coach sees the sessions they
// are running. The owner has no feed: an owner token answers 404, the same
// as a token that was never issued.
//
// Deploy with the login check off:
//   supabase functions deploy calendar-feed --no-verify-jwt
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  CACHE_CONTROL,
  businessTimeZone,
  clientLabelForStaff,
  calendarSyncAllowed,
  coachLabelForClient,
  esc,
  eventRevision,
  fold,
  icsStamp,
  sessionMinutes,
  wallTimeToUtc,
} from "../_shared/calendarFeed.mjs";

const PAST_DAYS = 30;

const titleCase = (s: string) =>
  String(s ?? "").replace(/[-_]/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()).trim();

serve(async (req) => {
  try {
    const token = new URL(req.url).searchParams.get("token");
    if (!token) return new Response("Missing token.", { status: 400 });

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: profile } = await admin.from("profiles")
      .select("id, role").eq("calendar_token", token).maybeSingle();
    if (!profile || !calendarSyncAllowed(profile.role)) {
      return new Response("Not found.", { status: 404 });
    }

    const { data: settingsRow } = await admin.from("platform_settings")
      .select("data").eq("id", "global").maybeSingle();
    const tz = businessTimeZone(settingsRow?.data);
    const businessName = settingsRow?.data?.workouts?.businessName
      || settingsRow?.data?.businessName
      || "ONE Fitness";

    const since = new Date(Date.now() - PAST_DAYS * 86400000).toISOString().slice(0, 10);
    const isStaff = profile.role === "coach" || profile.role === "owner";
    const { data: bookings } = await admin.from("bookings")
      .select("id, date, slot_min, duration_min, session_type, discipline, location, client_id, trainer_id, updated_at")
      .eq(isStaff ? "trainer_id" : "client_id", profile.id)
      .gte("date", since)
      .is("cancelled_at", null)
      .order("date");

    const rows = bookings ?? [];
    const otherIds = [...new Set(rows.map((b) => (isStaff ? b.client_id : b.trainer_id)).filter(Boolean))];
    const names = new Map<string, string>();
    if (otherIds.length && isStaff) {
      const { data: others } = await admin.from("profiles").select("id, name").in("id", otherIds);
      for (const o of others ?? []) names.set(o.id, clientLabelForStaff(o.name));
    }
    if (otherIds.length && !isStaff) {
      await Promise.all(otherIds.map(async (id) => {
        const { data, error } = await admin.rpc("coach_public_name", { p_id: id });
        if (!error && data) {
          names.set(id, coachLabelForClient(data));
          return;
        }
        const { data: trainer } = await admin.from("trainers")
          .select("coach_name").eq("profile_id", id).maybeSingle();
        names.set(id, coachLabelForClient(trainer?.coach_name));
      }));
    }

    const now = icsStamp(new Date());
    const lines: string[] = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//ONE Fitness//Schedule Feed//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      `X-WR-CALNAME:${esc(`${businessName} — My Sessions`)}`,
      `X-WR-TIMEZONE:${esc(tz)}`,
      "REFRESH-INTERVAL;VALUE=DURATION:PT1H",
      "X-PUBLISHED-TTL:PT1H",
    ];

    for (const b of rows) {
      const start = wallTimeToUtc(b.date, Number(b.slot_min) || 0, tz);
      const end = new Date(start.getTime() + sessionMinutes(b.duration_min) * 60000);
      const other = names.get(isStaff ? b.client_id : b.trainer_id) ?? "";
      const type = titleCase(b.session_type || "");
      const disc = titleCase(b.discipline || "");
      const summary = [[type, disc].filter(Boolean).join(" · "), other].filter(Boolean).join(" — ");
      const loc = (b.location ?? null) as { name?: string; address?: string; hint?: string } | null;
      const locLine = loc?.address || loc?.name || "";
      const revision = eventRevision(b.updated_at);

      lines.push(
        "BEGIN:VEVENT",
        `UID:booking-${esc(b.id)}@onefitness`,
        `DTSTAMP:${now}`,
        ...(revision.lastModified ? [`LAST-MODIFIED:${revision.lastModified}`] : []),
        `SEQUENCE:${revision.sequence}`,
        `DTSTART:${icsStamp(start)}`,
        `DTEND:${icsStamp(end)}`,
        `SUMMARY:${esc(summary || "Session")}`,
        ...(locLine ? [`LOCATION:${esc(locLine)}`] : []),
        `DESCRIPTION:${esc(
          [
            type && disc ? `${type} · ${disc}` : type || disc,
            other ? (isStaff ? `Client: ${other}` : `Coach: ${other}`) : "",
            loc?.name && loc?.address ? loc.name : "",
            loc?.hint ?? "",
            `Booked through ${businessName}.`,
          ].filter(Boolean).join("\n"),
        )}`,
        "STATUS:CONFIRMED",
        "END:VEVENT",
      );
    }
    lines.push("END:VCALENDAR");

    return new Response(lines.map(fold).join("\r\n") + "\r\n", {
      headers: {
        "Content-Type": "text/calendar; charset=utf-8",
        "Content-Disposition": 'inline; filename="one-fitness.ics"',
        "Cache-Control": CACHE_CONTROL,
      },
    });
  } catch (e) {
    console.error("calendar-feed failed:", e instanceof Error ? e.message : String(e));
    return new Response("Calendar temporarily unavailable.", { status: 500 });
  }
});
