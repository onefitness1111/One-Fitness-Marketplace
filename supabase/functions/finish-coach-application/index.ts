// Saves a finished Apply now form and emails the owner. Proposed. Not
// deployed until you deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { emailOwners } from "../_shared/requestNotify.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

function text(value: unknown, max: number, label: string, required = true): string {
  const s = String(value ?? "").trim();
  if (required && !s) throw new Error(`${label} is required.`);
  if (s.length > max) throw new Error(`${label} is too long.`);
  return s;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const body = await req.json();
    const id = String(body.applicationId ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error("That application link is not valid. Start again.");

    const first = text(body.firstName, 80, "First name");
    const last = text(body.lastName, 80, "Last name");
    const email = text(body.email, 200, "Email").toLowerCase();
    if (!email.includes("@")) throw new Error("Enter a real email address.");
    const birthday = text(body.birthday, 20, "Birthday");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(birthday)) throw new Error("Birthday should be a date.");
    const phone = text(body.phone, 40, "Phone");
    const pitch = text(body.pitch, 4000, "What makes you a great coach");
    const bio = text(body.bio, 4000, "Bio");
    const locationName = text(body.locationName, 200, "Location name");
    const locationAddress = text(body.locationAddress, 300, "Location address");
    const checks = body.locationChecks ?? {};
    if (checks.permission !== true || checks.clientsAllowed !== true || checks.followRules !== true) {
      throw new Error("Tick every box on the location approval notice.");
    }

    const clipPath = body.clipPath ? String(body.clipPath) : null;
    const documentPaths = Array.isArray(body.documentPaths) ? body.documentPaths.slice(0, 12) : [];
    const beforeAfterPaths = Array.isArray(body.beforeAfterPaths) ? body.beforeAfterPaths.slice(0, 12) : [];
    const locationPhotoPaths = Array.isArray(body.locationPhotoPaths) ? body.locationPhotoPaths.slice(0, 8) : [];
    const paths = [
      ...(clipPath ? [clipPath] : []),
      ...documentPaths.map((d: { path?: string }) => d.path),
      ...beforeAfterPaths.map((d: { path?: string }) => d.path),
      ...locationPhotoPaths,
    ].filter(Boolean).map(String);
    if (paths.some((p) => !p.startsWith(`${id}/`))) throw new Error("A file is in the wrong place. Start again.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: existing } = await admin.from("coach_applications").select("id").eq("id", id).maybeSingle();
    if (existing) throw new Error("This application was already sent.");

    const { error } = await admin.from("coach_applications").insert({
      id,
      first_name: first,
      last_name: last,
      email,
      birthday,
      phone,
      pitch,
      bio,
      location_name: locationName,
      location_address: locationAddress,
      location_checks: checks,
      clip_path: clipPath,
      document_paths: documentPaths,
      before_after_paths: beforeAfterPaths,
      location_photo_paths: locationPhotoPaths,
    });
    if (error) throw error;

    await emailOwners(
      admin,
      "New coach application",
      `${first} ${last} applied to coach at ONE Fitness.\n\nEmail: ${email}\nPhone: ${phone}\nLocation: ${locationName}\n\nOpen the app, then Requests, to approve or deny it.`,
    );

    return json({ ok: true });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("finish-coach-application failed:", message);
    return json({ error: message }, 400);
  }
});
