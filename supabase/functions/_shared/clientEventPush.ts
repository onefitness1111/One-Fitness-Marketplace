// Database side of client-event alerts for send-push. The rules live in
// clientEventAlerts.mjs (unit-tested with node --test).
//
// Every read here filters on the caller's own id, so the event must be the
// caller's own. Recipients, title, and body come only from the server.
// Push only, never SMS.
import { sendPush } from "./sendPush.ts";
import type { Admin } from "./messagingGuard.ts";
import {
  CLIENT_ALERTS_PER_HOUR,
  EVENT_WINDOW_MIN,
  buildAlert,
  callerTargetAllowed,
  classifyClientPush,
} from "./clientEventAlerts.mjs";

export type ClientPushResult = { ok: boolean; sent: number; skipped?: string };

async function ownerIds(admin: Admin): Promise<string[]> {
  const { data } = await admin.from("profiles").select("id").eq("role", "owner").is("deleted_at", null);
  return (data ?? []).map((r: { id: string }) => r.id);
}

export async function handleClientPush(
  admin: Admin,
  callerId: string,
  body: { profileId?: unknown; title?: unknown },
): Promise<ClientPushResult> {
  const profileId = String(body.profileId ?? "").trim();
  const classified = classifyClientPush({ callerId, profileId, title: body.title });
  // The app's own "Welcome" / "Booking confirmed" style notices; client-notify
  // already confirms these, so do nothing and report success.
  if (classified.kind === "self") return { ok: true, sent: 0, skipped: "self" };
  if (!classified.kind) return { ok: false, sent: 0, skipped: "not-allowed" };

  const nowMs = Date.now();
  const since = new Date(nowMs - EVENT_WINDOW_MIN * 60_000).toISOString();
  const { data: me } = await admin.from("profiles").select("name, created_at, role").eq("id", callerId).maybeSingle();
  if (me?.role !== "client") return { ok: false, sent: 0, skipped: "not-allowed" };

  // deno-lint-ignore no-explicit-any
  const facts: any = { nowMs, clientName: me?.name ?? "", owners: [] };
  switch (classified.kind) {
    case "booking": {
      const { data } = await admin.from("bookings")
        .select("id, trainer_id, date, slot_min, created_at")
        .eq("client_id", callerId).eq("trainer_id", profileId).gte("created_at", since)
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      facts.booking = data;
      break;
    }
    case "cancel": {
      const { data } = await admin.from("cancelled_visits")
        .select("booking_id, trainer_id, date, slot_min, status, cancelled_at")
        .eq("client_id", callerId).eq("trainer_id", profileId).gte("cancelled_at", since)
        .order("cancelled_at", { ascending: false }).limit(1).maybeSingle();
      facts.cancel = data;
      break;
    }
    case "signup":
      facts.owners = await ownerIds(admin);
      facts.profileCreatedAt = me?.created_at;
      break;
    case "measurement": {
      facts.owners = await ownerIds(admin);
      // Stamped by trg_client_records_stamp_measurement when an entry is added.
      const { data } = await admin.from("client_records").select("measurements_at").eq("profile_id", callerId).maybeSingle();
      facts.measurementAt = data?.measurements_at;
      break;
    }
    case "intake": {
      facts.owners = await ownerIds(admin);
      const { data } = await admin.from("program_refresh_flags")
        .select("kind, flagged_at").eq("client_id", callerId).gte("flagged_at", since)
        .order("flagged_at", { ascending: false });
      const rows = (data ?? []) as { kind: string; flagged_at: string }[];
      const wantNutrition = classified.intakeKind === "nutrition";
      facts.intakeFlag = rows.find((r) => (r.kind === "nutrition") === wantNutrition) ?? null;
      break;
    }
  }

  const alert = buildAlert(classified, facts);
  if (!alert) return { ok: false, sent: 0, skipped: "no-matching-event" };
  if (!callerTargetAllowed(alert, profileId)) return { ok: false, sent: 0, skipped: "wrong-recipient" };

  // Per-client cap, then one row per (event, recipient) so repeats send nothing.
  const hourAgo = new Date(nowMs - 3_600_000).toISOString();
  const { count } = await admin.from("client_event_alerts")
    .select("ref", { count: "exact", head: true })
    .eq("caller_id", callerId).gte("created_at", hourAgo);
  if ((count ?? 0) >= CLIENT_ALERTS_PER_HOUR) return { ok: false, sent: 0, skipped: "rate-limited" };

  let sent = 0;
  for (const recipient of alert.recipients) {
    const { data: claimed, error } = await admin.from("client_event_alerts")
      .upsert(
        { caller_id: callerId, kind: alert.kind, ref: alert.ref, recipient_id: recipient },
        { onConflict: "kind,ref,recipient_id", ignoreDuplicates: true },
      )
      .select("ref");
    if (error) {
      console.error("send-push: client alert claim failed:", error.message);
      continue;
    }
    if (!claimed?.length) continue; // already sent for this event
    const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", recipient);
    const tokens = (rows ?? []).map((r: { token: string }) => r.token);
    await sendPush(tokens, alert.title, alert.body, { type: "client-event", kind: alert.kind });
    sent += tokens.length;
  }
  return { ok: true, sent };
}
