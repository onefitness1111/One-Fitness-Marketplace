// Sign-in check for plate estimates and restaurant suggestions.
// Coaches are refused. The signed-in client is allowed, and so is the owner.
// Nothing returned to the phone uses the word AI.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { clientSafeMessage, stripAiWords } from "./aiWords.mjs";

export const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

export async function requireClientOrOwner(req: Request): Promise<{ id: string; role: string }> {
  const authed = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user }, error } = await authed.auth.getUser();
  if (error || !user) throw new Error("Not signed in.");

  const admin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );
  const { data } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
  const role = String(data?.role ?? "");
  if (role !== "client" && role !== "owner") {
    throw new Error("That isn't available on this account.");
  }
  return { id: user.id, role };
}

export function scrub(value: unknown, max = 80): string {
  return stripAiWords(value).slice(0, max);
}

/// An error message for the phone. Anything that mentions AI (or a model
/// or AI company) becomes [fallback], so a client never sees the word.
export function safeError(message: unknown, fallback: string): string {
  return clientSafeMessage(String(message ?? "").slice(0, 180), fallback);
}

export function clamp(value: unknown, max: number): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.round(Math.min(n, max) * 10) / 10;
}

export function parseModelJson(text: string): Record<string, unknown> {
  const trimmed = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/```$/, "").trim();
  const parsed = JSON.parse(trimmed);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Couldn't read the estimate.");
  }
  return parsed as Record<string, unknown>;
}

export async function askModel(payload: unknown): Promise<string> {
  const key = (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
  if (!key) throw new Error("Estimates aren't available right now.");
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    console.error("estimate model status", res.status);
    throw new Error("Estimates aren't available right now.");
  }
  const message = await res.json();
  // deno-lint-ignore no-explicit-any
  const block = (message.content || []).find((b: any) => b.type === "text");
  const text = block?.text;
  if (typeof text !== "string" || !text.trim()) throw new Error("Couldn't make an estimate. Try again.");
  return text;
}
