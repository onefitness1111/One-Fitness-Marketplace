// Saves a coach's time off and tells the clients whose sessions were cancelled.
//
// Not deployed. The database function does the cancel and the chat message
// in one transaction. This function only runs the push, and a text for a
// client who already opted in to texts — the same pair a coach cancel uses
// (sendPush + smsClientIfOptedIn). A retry is told not to notify again.
//
// Deploy this function after applying
// supabase/migrations/20261120213000_coach_unavailability.sql.

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendPush } from "../_shared/sendPush.ts";
import { smsClientIfOptedIn } from "../_shared/notifySms.ts";
import { CORS_HEADERS, json, requireStaff } from "../_shared/messagingGuard.ts";

function whenLabel(date: string, slot: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const day = new Date(Date.UTC(y, (m || 1) - 1, d || 1));
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day.getUTCDay()];
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const h = Math.floor(slot / 60);
  const min = slot % 60;
  const h12 = h % 12 === 0 ? 12 : h % 12;
  const ampm = h < 12 ? "AM" : "PM";
  return `${weekday}, ${months[(m || 1) - 1]} ${d} at ${h12}:${String(min).padStart(2, "0")} ${ampm}`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { admin, userId, role } = await requireStaff(req);
    const body = await req.json();
    const trainerId = String(body.trainerId ?? "").trim();
    if (!trainerId) throw new Error("Choose a coach.");
    if (role !== "owner" && userId !== trainerId) {
      throw new Error("You can only set unavailability for yourself.");
    }

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data, error } = await authed.rpc("apply_coach_unavailability", {
      p_trainer_id: trainerId,
      p_entry: body.entry ?? {},
    });
    if (error) throw new Error(error.message);
    const result = (data ?? {}) as {
      shouldNotify?: boolean;
      coachName?: string;
      clientNote?: string;
      clients?: { id: string; sessions?: number; date?: string; slot?: number }[];
    };

    if (result.shouldNotify === true) {
      const coachName = String(result.coachName || "").trim() || "your coach";
      const note = String(result.clientNote || "").trim();
      for (const client of result.clients || []) {
        if (!client?.id) continue;
        const sessions = Number(client.sessions || 1);
        const when = client.date ? whenLabel(client.date, Number(client.slot || 0)) : "";
        const title = "Session cancelled";
        const text = sessions === 1
          ? `${coachName} cancelled your session${when ? ` on ${when}` : ""}.${note ? ` ${note}` : ""}`
          : `${coachName} cancelled ${sessions} sessions.${note ? ` ${note}` : ""}`;
        const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", client.id);
        const tokens = (rows || []).map((r: { token: string }) => r.token).filter(Boolean);
        await sendPush(tokens, title, text, { kind: "coach_unavailable" });
        try {
          await smsClientIfOptedIn(admin, client.id, `${title}. ${text}`);
        } catch (e) {
          console.error("save-coach-unavailability: text failed:", e instanceof Error ? e.message : String(e));
        }
      }
    }

    return json(data);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("save-coach-unavailability failed:", message);
    const status = message.includes("only set unavailability") ? 403 : 400;
    return json({ error: message }, status);
  }
});
