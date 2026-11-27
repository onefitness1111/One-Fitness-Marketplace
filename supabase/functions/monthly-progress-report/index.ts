// Monthly progress report, by phone notification and email.
//
// Proposed. Not deployed until you deploy this function.
// A timer calls it at 8:20am Pacific on the 1st, with the header
// x-cron-secret set to the Vault secret apply_requests_cron (the same
// secret the freeze job uses). The password is not stored in this file.
//
// The report covers the month that just ended: sessions checked in,
// strength gains, weight and inch changes, and progress photos. Photo
// links are the same private-bucket signed links the app uses, kept for
// 7 days so the email can still open them. Each client is sent once.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";
import { sendEmail } from "../_shared/sendEmail.ts";
import { bodyChanges, num, sessionsDone, strengthGains } from "../_shared/progressSummary.ts";
import { EMAIL_SIGNOFF } from "../_shared/businessName.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

function previousMonth(now = new Date()): { key: string; start: string; end: string; label: string; day: number } {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now).split("-");
  const year = Number(parts[0]);
  const month = Number(parts[1]);
  const day = Number(parts[2]);
  const prev = month === 1 ? 12 : month - 1;
  const prevYear = month === 1 ? year - 1 : year;
  const lastDay = new Date(Date.UTC(prevYear, prev, 0)).getUTCDate();
  const mm = String(prev).padStart(2, "0");
  return {
    key: `${prevYear}-${mm}`,
    start: `${prevYear}-${mm}-01`,
    end: `${prevYear}-${mm}-${String(lastDay).padStart(2, "0")}`,
    label: `${MONTHS[prev - 1]} ${prevYear}`,
    day,
  };
}

function asList(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.filter((e) => e && typeof e === "object") as Record<string, unknown>[] : [];
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const admin = createClient(url, serviceKey);

    const cron = req.headers.get("x-cron-secret");
    const { data: secretRow, error: secretErr } = await admin.rpc("cron_vault_secret");
    if (secretErr) console.error("cron vault read failed");
    const expected = typeof secretRow === "string" ? secretRow : "";
    const cronOk = expected.length > 0 && cron === expected;

    let ownerForceId: string | null = null;
    if (!cronOk) {
      const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await authed.auth.getUser();
      if (!user) throw new Error("Not signed in.");
      const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (profile?.role !== "owner") throw new Error("Only the owner can send progress reports.");
      const body = await req.json().catch(() => ({}));
      ownerForceId = typeof body?.clientId === "string" ? body.clientId : null;
      if (!ownerForceId) throw new Error("Name the one client to send, or wait for the 1st.");
    }

    const period = previousMonth();
    if (cronOk && period.day !== 1) {
      return new Response(JSON.stringify({ ok: true, skipped: "not the 1st" }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    let profileQuery = admin.from("profiles").select("id, email, name, role").eq("role", "client").is("deleted_at", null).is("banned_at", null);
    if (ownerForceId) profileQuery = profileQuery.eq("id", ownerForceId);
    const { data: people, error: peopleErr } = await profileQuery;
    if (peopleErr) throw peopleErr;

    let sent = 0;
    for (const person of people || []) {
      const clientId = String(person.id || "");
      if (!clientId) continue;

      const { data: claimed, error: claimErr } = await admin
        .from("monthly_progress_sends")
        .insert({ client_id: clientId, month: period.key })
        .select("client_id")
        .maybeSingle();
      if (claimErr) {
        if (claimErr.code === "23505") continue;
        console.error("progress report claim failed");
        continue;
      }
      if (!claimed) continue;

      const { data: record } = await admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle();
      const data = (record?.data || {}) as Record<string, unknown>;
      const logs = asList(data.workoutLogs);
      const measures = asList(data.measurements);
      const photos = asList(data.photos).filter((p) => {
        const date = String(p.date || "").slice(0, 10);
        return date >= period.start && date <= period.end;
      });

      const { data: bookings } = await admin
        .from("bookings")
        .select("date, attendance_status, status")
        .eq("client_id", clientId)
        .gte("date", period.start)
        .lte("date", period.end);
      const sessions = sessionsDone(bookings || [], period.start, period.end);
      const workouts = logs.filter((l) => {
        const date = String(l.date || "").slice(0, 10);
        return date >= period.start && date <= period.end;
      }).length;
      const gains = strengthGains(logs as never, period.start, period.end);
      const changes = bodyChanges(measures as never, period.start, period.end);

      if (sessions === 0 && workouts === 0 && gains.length === 0 && changes.length === 0 && photos.length === 0) {
        await admin.from("monthly_progress_sends").delete().eq("client_id", clientId).eq("month", period.key);
        continue;
      }

      const photoUrls: string[] = [];
      const orderedPhotos = [...photos].sort((a, b) => String(a.date || "").localeCompare(String(b.date || "")));
      const picked = orderedPhotos.length <= 2 ? orderedPhotos : [orderedPhotos[0], orderedPhotos[orderedPhotos.length - 1]];
      for (const photo of picked) {
        const path = String(photo.img || "");
        if (!path || path.startsWith("data:")) continue;
        const signed = await admin.storage.from("progress-photos").createSignedUrl(path, 60 * 60 * 24 * 7);
        const link = signed.data?.signedUrl;
        if (link) photoUrls.push(link);
      }

      const lines = [
        `${period.label} at ONE Fitness`,
        "",
        `Sessions checked in: ${sessions}`,
        `Workouts logged: ${workouts}`,
      ];
      if (gains.length) {
        lines.push("", "Strength");
        for (const g of gains.slice(0, 6)) {
          lines.push(`${g.name}: ${num(g.before)} lb to ${num(g.after)} lb`);
        }
      }
      if (changes.length) {
        lines.push("", "Body");
        for (const c of changes) {
          const unit = c.label === "Weight" ? "lb" : "in";
          lines.push(`${c.label}: ${num(c.before)} to ${num(c.after)} ${unit}`);
        }
      }
      if (photoUrls.length) {
        lines.push("", "Progress photos (these links last 7 days; the photos stay in the app):");
        photoUrls.forEach((link, i) => lines.push(`Photo ${i + 1}: ${link}`));
      }
      lines.push("", EMAIL_SIGNOFF);
      const text = lines.join("\n");

      const htmlBits = [
        `<div style="font-family:Georgia,serif;background:#000;color:#fff;padding:28px">`,
        `<p style="letter-spacing:2px;color:#d9d9d9;font-size:12px;margin:0">ONE FITNESS</p>`,
        `<h1 style="font-size:22px;margin:8px 0 18px">${period.label}</h1>`,
        `<p style="margin:0 0 8px">Sessions checked in: <b>${sessions}</b></p>`,
        `<p style="margin:0 0 16px">Workouts logged: <b>${workouts}</b></p>`,
      ];
      if (gains.length) {
        htmlBits.push(`<p style="color:#8b8a85;margin:0 0 6px">Strength</p>`);
        for (const g of gains.slice(0, 6)) {
          htmlBits.push(`<p style="margin:0 0 4px">${g.name}: ${num(g.before)} lb to ${num(g.after)} lb</p>`);
        }
      }
      if (changes.length) {
        htmlBits.push(`<p style="color:#8b8a85;margin:14px 0 6px">Body</p>`);
        for (const c of changes) {
          const unit = c.label === "Weight" ? "lb" : "in";
          htmlBits.push(`<p style="margin:0 0 4px">${c.label}: ${num(c.before)} to ${num(c.after)} ${unit}</p>`);
        }
      }
      for (const link of photoUrls) {
        htmlBits.push(`<p style="margin:14px 0 0"><img src="${link}" alt="Progress photo" style="max-width:100%;border-radius:8px" /></p>`);
      }
      if (photoUrls.length) {
        htmlBits.push(`<p style="color:#8b8a85;font-size:12px">Photo links last 7 days. The photos stay in the app.</p>`);
      }
      htmlBits.push(`</div>`);

      const first = String(person.name || "").trim().split(/\s+/)[0] || "there";
      await notifyProfile(
        admin,
        clientId,
        `${period.label} progress`,
        `${first}, your month is in: ${sessions} sessions checked in. The full report is in your email.`,
        false,
      );
      const email = String(person.email || "").trim();
      if (email) await sendEmail(email, `Your ${period.label} progress`, text, htmlBits.join(""));
      sent += 1;
    }

    return new Response(JSON.stringify({ ok: true, sent, month: period.key }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Could not send progress reports.";
    console.error("monthly-progress-report failed");
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
