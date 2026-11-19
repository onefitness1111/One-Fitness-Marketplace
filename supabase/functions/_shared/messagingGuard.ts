// Shared checks for send-email, send-sms, send-push, and client-notify.
//
// Proposed replacement helper. Not deployed. The live project still runs
// the previous functions until these folders are deployed.
//
// A caller who is only signed in is not enough. The owner can message any
// member. A coach can message clients and other staff (Team Chat), never an
// address that is not on an account. Clients do not use the open senders.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const WINDOW_MS = 10 * 60 * 1000;
const MAX_IN_WINDOW = 200;

export const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// deno-lint-ignore no-explicit-any
export type Admin = any;

export type Member = {
  id: string;
  role: string;
  email: string;
  phone: string;
  name: string;
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

export function adminClient(): Admin {
  return createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );
}

export async function callerUser(req: Request): Promise<{ id: string }> {
  const authed = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user }, error } = await authed.auth.getUser();
  if (error || !user) throw new Error("Not signed in.");
  return user;
}

export async function callerRole(admin: Admin, userId: string): Promise<string> {
  const { data } = await admin.from("profiles").select("role").eq("id", userId).maybeSingle();
  return String(data?.role ?? "");
}

export async function requireStaff(req: Request): Promise<{ admin: Admin; userId: string; role: "owner" | "coach" }> {
  const user = await callerUser(req);
  const admin = adminClient();
  const role = await callerRole(admin, user.id);
  if (role !== "owner" && role !== "coach") {
    throw new Error("Only the owner or a coach can send that.");
  }
  return { admin, userId: user.id, role };
}

export async function memberById(admin: Admin, profileId: string): Promise<Member | null> {
  if (!profileId) return null;
  const { data } = await admin
    .from("profiles")
    .select("id, role, email, phone, name")
    .eq("id", profileId)
    .maybeSingle();
  if (!data?.id) return null;
  return {
    id: data.id as string,
    role: String(data.role ?? ""),
    email: String(data.email ?? "").trim(),
    phone: String(data.phone ?? "").trim(),
    name: String(data.name ?? "").trim(),
  };
}

export async function memberByEmail(admin: Admin, email: string): Promise<Member | null> {
  const wanted = email.trim().toLowerCase();
  if (!wanted) return null;
  const { data } = await admin.from("profiles").select("id, role, email, phone, name");
  const hit = (data ?? []).find((row: Member) => String(row.email ?? "").trim().toLowerCase() === wanted);
  if (!hit?.id) return null;
  return {
    id: hit.id as string,
    role: String(hit.role ?? ""),
    email: String(hit.email ?? "").trim(),
    phone: String(hit.phone ?? "").trim(),
    name: String(hit.name ?? "").trim(),
  };
}

/** Owner and coach may message members only — never a typed-in outside address. */
export function assertStaffMayMessage(callerRoleName: string, target: Member): void {
  if (callerRoleName !== "owner" && callerRoleName !== "coach") {
    throw new Error("Only the owner or a coach can send that.");
  }
  if (!["client", "coach", "owner"].includes(target.role)) {
    throw new Error("That recipient isn't a member of ONE Fitness.");
  }
}

export function clip(value: unknown, max: number, label: string): string {
  const text = String(value ?? "").trim();
  if (!text) throw new Error(`${label} is required.`);
  if (text.length > max) throw new Error(`${label} is too long.`);
  return text;
}

/** Stops a script from sending thousands of messages. A normal gym blast still fits. */
export async function enforceRateLimit(admin: Admin, senderId: string, channel: string): Promise<void> {
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  const { count, error } = await admin
    .from("outbound_message_log")
    .select("id", { count: "exact", head: true })
    .eq("sender_id", senderId)
    .gte("created_at", since);
  if (error) {
    console.error("rate limit lookup failed:", error.message);
    throw new Error("Couldn't send just now. Try again in a minute.");
  }
  if ((count ?? 0) >= MAX_IN_WINDOW) {
    throw new Error("That's a lot of messages in a short time. Wait a few minutes and try again.");
  }
  const { error: insertError } = await admin.from("outbound_message_log").insert({
    sender_id: senderId,
    channel,
  });
  if (insertError) {
    console.error("rate limit insert failed:", insertError.message);
    throw new Error("Couldn't send just now. Try again in a minute.");
  }
}
