// Tells the owner a report or block needs a look (Apple guideline 1.2: act
// on reports within 24 hours). The app calls this right after it saves the
// report or block row (SupabaseService.submitReport / blockUser); before
// this file existed that call failed quietly and nobody was told.
//
// - Signed-in callers only (verify_jwt = true), and only about a row they
//   actually just made: a report they filed, or a block they placed, in the
//   last 15 minutes. Anything else is ignored.
// - One alert per caller + kind + person per hour.
// - The owner gets a push and an email with the kind, category and the
//   number of open reports. No names, phones, emails or the reported words:
//   those stay in the app's report list.
// - No text message.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { EMAIL_SIGNOFF } from "../_shared/businessName.mjs";
import { CORS_HEADERS, adminClient, callerUser, json } from "../_shared/messagingGuard.ts";
import { moderationAlert } from "../_shared/moderationAlert.mjs";
import { sendEmail } from "../_shared/sendEmail.ts";
import { sendPush } from "../_shared/sendPush.ts";

const RECENT_MS = 15 * 60 * 1000;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const user = await callerUser(req);
    const body = await req.json().catch(() => ({}));
    const kind = body?.kind === "block" ? "block" : body?.kind === "report" ? "report" : "";
    if (!kind) return json({ ok: false, skipped: "unknown kind" }, 400);
    const target = typeof body?.reportedUserId === "string" ? body.reportedUserId : "";

    const admin = adminClient();
    const since = new Date(Date.now() - RECENT_MS).toISOString();
    let category = "";
    if (kind === "report") {
      let q = admin.from("reports").select("id, content_type, reason").eq("reporter_id", user.id).gte("created_at", since)
        .order("created_at", { ascending: false }).limit(1);
      if (target) q = q.eq("reported_user_id", target);
      const { data } = await q;
      const row = data?.[0];
      if (!row) return json({ ok: false, skipped: "no recent report" });
      category = [row.content_type, row.reason].filter(Boolean).join(", ");
    } else {
      if (!target) return json({ ok: false, skipped: "no recent block" });
      const { data } = await admin.from("blocks").select("id").eq("blocker_id", user.id).eq("blocked_id", target)
        .gte("created_at", since).limit(1);
      if (!data?.length) return json({ ok: false, skipped: "no recent block" });
    }

    const { data: owners } = await admin.from("profiles").select("id, email").eq("role", "owner").is("deleted_at", null);
    if (!owners?.length) return json({ ok: false, skipped: "no owner" });

    const hour = new Date().toISOString().slice(0, 13);
    const { count: openReports } = await admin.from("reports").select("id", { count: "exact", head: true }).is("reviewed_at", null);
    const alert = moderationAlert({ kind, category, openReports: openReports ?? 0 });

    let alerted = 0;
    for (const owner of owners) {
      const { error } = await admin.from("scheduled_notices").insert({
        kind: `moderation-${kind}`,
        ref: `${user.id}:${target || "-"}:${hour}`,
        profile_id: owner.id,
      });
      if (error) continue; // already told this hour
      const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", owner.id);
      await sendPush((rows || []).map((r: { token: string }) => r.token), alert.title, alert.body);
      if (owner.email) await sendEmail(owner.email, alert.title, `${alert.body}\n\nOpen the app to review it.\n\n${EMAIL_SIGNOFF}`);
      alerted++;
    }
    console.log(`notify-moderation: ${kind}, ${alerted} owner alert(s)`);
    return json({ ok: true, alerted });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("notify-moderation failed:", message);
    return json({ ok: false, error: message === "Not signed in." ? message : "Couldn't send the alert." }, message === "Not signed in." ? 401 : 500);
  }
});
