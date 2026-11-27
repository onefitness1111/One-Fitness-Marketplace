// Automatic texts: consent, quiet hours (9pm-8am Pacific), and the queue.
//
// sendAutoSms texts now, or queues the text in sms_outbox until 8:00am
// Pacific. drainSmsOutbox sends what is due; send-scheduled-reminders runs
// it every hour. Consent is checked again when a queued text goes out, so a
// STOP overnight still wins.

import { businessText } from "./businessName.mjs";
import { autoSmsDecision } from "./autoSmsRules.mjs";
import { quietHoursEnd, smsQuietHours } from "./quietHours.mjs";
import { sendSmsDetailed } from "./sendSms.ts";

// deno-lint-ignore no-explicit-any
type Admin = any;

export type AutoSmsOutcome = "sent" | "deferred" | "already queued" | string;

export type AutoSmsInput = {
  profileId: string;
  text: string;
  /** What kind of text, for the log and the queue: "reminder", "waitlist", "broadcast", ... */
  kind: string;
  /** Optional dedupe key. The same kind + ref + person is queued once. */
  ref?: string | null;
  /** A queued text past this time is dropped (a waitlist offer that ran out). */
  expiresAt?: string | null;
  /** Already prefixed (a broadcast with its own sender name). Default adds "ONE Fitness Marketplace: ". */
  raw?: boolean;
};

export async function loadTextPerson(admin: Admin, profileId: string) {
  const { data: profile } = await admin
    .from("profiles")
    .select("id, role, phone, sms_opted_out, sms_undeliverable_at, deleted_at")
    .eq("id", profileId)
    .maybeSingle();
  if (!profile || profile.deleted_at) return null;
  const { data: client } = await admin
    .from("clients")
    .select("sms_opt_in, sms_declined_at")
    .eq("profile_id", profileId)
    .maybeSingle();
  return {
    id: profile.id as string,
    role: String(profile.role || ""),
    phone: String(profile.phone || "").trim(),
    optedOut: profile.sms_opted_out === true,
    undeliverable: profile.sms_undeliverable_at != null,
    smsOptIn: client?.sms_opt_in === true,
    declined: client?.sms_declined_at != null,
  };
}

export async function sendAutoSms(admin: Admin, input: AutoSmsInput, now: Date = new Date()): Promise<AutoSmsOutcome> {
  const person = await loadTextPerson(admin, input.profileId);
  if (!person) return "skip: no account";
  const decision = autoSmsDecision(person, now);
  const body = input.raw ? String(input.text) : businessText(input.text);
  if (decision === "defer") {
    const { error } = await admin.from("sms_outbox").insert({
      profile_id: person.id,
      body,
      kind: input.kind,
      ref: input.ref ?? null,
      not_before: quietHoursEnd(now).toISOString(),
      expires_at: input.expiresAt ?? null,
    });
    if (error) {
      if ((error as { code?: string }).code === "23505") return "already queued";
      console.error(`autoSms: queue failed: ${error.message}`);
      return "skip: queue failed";
    }
    return "deferred";
  }
  if (decision !== "send") return decision;
  const result = await sendSmsDetailed(person.phone, body, { kind: input.kind });
  if (result.ok) return "sent";
  return `skip: ${result.skipped ?? "twilio error"}`;
}

/** Sends queued texts that are due. Does nothing during quiet hours. */
export async function drainSmsOutbox(admin: Admin, now: Date = new Date()): Promise<Record<string, number>> {
  const counts: Record<string, number> = { sent: 0, skipped: 0, expired: 0 };
  if (smsQuietHours(now)) return counts;
  const { data: due, error } = await admin
    .from("sms_outbox")
    .select("id, profile_id, body, kind, expires_at")
    .eq("status", "pending")
    .lte("not_before", now.toISOString())
    .order("created_at", { ascending: true })
    .limit(300);
  if (error) {
    console.error(`autoSms: outbox read failed: ${error.message}`);
    return counts;
  }
  for (const row of due ?? []) {
    // Claim it so two runs never send the same text.
    const { data: claimed } = await admin
      .from("sms_outbox")
      .update({ status: "sending" })
      .eq("id", row.id)
      .eq("status", "pending")
      .select("id");
    if (!claimed || claimed.length === 0) continue;
    let outcome: string;
    if (row.expires_at && Date.parse(row.expires_at as string) < now.getTime()) {
      outcome = "expired";
      counts.expired += 1;
    } else {
      const person = await loadTextPerson(admin, row.profile_id as string);
      const decision = person ? autoSmsDecision(person, now) : "skip: no account";
      if (decision === "send" && person) {
        const result = await sendSmsDetailed(person.phone, String(row.body), { kind: String(row.kind || "queued") });
        outcome = result.ok ? "sent" : `skip: ${result.skipped ?? "twilio error"}`;
      } else {
        outcome = decision === "defer" ? "skip: still quiet" : decision;
      }
      if (outcome === "sent") counts.sent += 1;
      else counts.skipped += 1;
    }
    await admin
      .from("sms_outbox")
      .update({ status: outcome === "sent" ? "sent" : outcome === "expired" ? "expired" : "skipped", outcome, sent_at: now.toISOString() })
      .eq("id", row.id);
  }
  return counts;
}
