// One push per client message to a coach or the owner.
// chat-auto-reply-sms and client-notify both try to send it. The first
// insert wins; the other sees the same message id and does not push again.

import { staffPushCopy } from "./chatRouting.mjs";
import { sendPush } from "./sendPush.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// deno-lint-ignore no-explicit-any
type Admin = any;

export function isMessageUuid(value: string): boolean {
  return UUID.test(value);
}

/** True when this call should send the push. False when that message was already claimed. */
export async function claimStaffPush(admin: Admin, messageId: string): Promise<boolean> {
  if (!isMessageUuid(messageId)) return true;
  const { error } = await admin.from("chat_staff_push").insert({ message_id: messageId });
  if (!error) return true;
  if ((error as { code?: string }).code === "23505") return false;
  console.warn(`chat staff push claim failed: ${(error as { message?: string }).message}`);
  return true;
}

export async function pushStaffForClientMessage(
  admin: Admin,
  opts: { messageId: string; staffId: string; clientName: string; body: string },
): Promise<"sent" | "skipped"> {
  const claimed = await claimStaffPush(admin, opts.messageId);
  if (!claimed) return "skipped";
  const { data: rows } = await admin.from("device_tokens").select("token").eq("profile_id", opts.staffId);
  const tokens = (rows || []).map((r: { token: string }) => r.token);
  const copy = staffPushCopy(opts.clientName, opts.body);
  await sendPush(tokens, copy.title, copy.body);
  return "sent";
}

/**
 * The message this alert belongs to. An id is used only when this client
 * sent it. Otherwise the newest message they just saved to this coach,
 * or to the business thread when the recipient is the owner.
 * Coach assignment is not consulted.
 */
export async function resolveStaffAlertMessageId(
  admin: Admin,
  opts: { explicitId?: string; senderId: string; staffId: string; staffRole: string; body?: string },
): Promise<string | null> {
  const explicit = String(opts.explicitId || "").trim();
  if (isMessageUuid(explicit)) {
    const { data } = await admin.from("messages").select("id, sender_id").eq("id", explicit).maybeSingle();
    if (data?.id && data.sender_id === opts.senderId) return data.id as string;
  }
  const since = new Date(Date.now() - 2 * 60 * 1000).toISOString();
  const { data: rows } = await admin
    .from("messages")
    .select("id, trainer_id, body, routed_to")
    .eq("sender_id", opts.senderId)
    .eq("who", "client")
    .gte("created_at", since)
    .order("created_at", { ascending: false })
    .limit(8);
  const list = (rows ?? []) as { id: string; trainer_id: string | null; body: string | null; routed_to: string | null }[];
  const aimed = list.filter((row) => row.trainer_id === opts.staffId);
  const pool = aimed.length > 0
    ? aimed
    : opts.staffRole === "owner"
      ? list.filter((row) => row.trainer_id == null && row.routed_to === "business")
      : [];
  if (opts.body) {
    const match = pool.find((row) => String(row.body || "") === opts.body);
    if (match) return match.id;
  }
  return pool[0]?.id ?? null;
}
