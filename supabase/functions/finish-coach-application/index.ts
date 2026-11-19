// Saves a finished Apply now form and emails the owner. Proposed. Not
// deployed until you deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { applicationEmailHtml, applicationReviewLines, applicationUploadError } from "../_shared/coachApplicationFiles.mjs";
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

    const clipPath = body.clipPath ? String(body.clipPath) : null;
    const documentPaths = (Array.isArray(body.documentPaths) ? body.documentPaths.slice(0, 20) : [])
      .map((doc: { name?: string; path?: string; kind?: string }) => ({
        name: String(doc?.name ?? "").slice(0, 200),
        path: String(doc?.path ?? ""),
        kind: String(doc?.kind ?? ""),
      }))
      .filter((doc: { path: string }) => doc.path.length > 0);
    const uploadError = applicationUploadError(documentPaths.map((doc: { kind: string }) => doc.kind));
    if (uploadError) throw new Error(uploadError);
    const beforeAfterPaths = (Array.isArray(body.beforeAfterPaths) ? body.beforeAfterPaths : [])
      .map((pair: { beforePath?: string; afterPath?: string }) => ({
        beforePath: String(pair?.beforePath ?? ""),
        afterPath: String(pair?.afterPath ?? ""),
      }))
      .filter((pair: { beforePath: string; afterPath: string }) => pair.beforePath && pair.afterPath);
    const locationPhotoPaths = (Array.isArray(body.locationPhotoPaths) ? body.locationPhotoPaths : [])
      .map(String)
      .filter(Boolean)
      .slice(0, 8);
    const fileCount = documentPaths.length + beforeAfterPaths.length * 2 + locationPhotoPaths.length;
    if (fileCount > 20) throw new Error("An application can hold up to 20 files.");
    if (locationPhotoPaths.length > 8) throw new Error("You can attach up to 8 location photos.");
    const paths = [
      ...(clipPath ? [clipPath] : []),
      ...documentPaths.map((d: { path?: string }) => d.path),
      ...beforeAfterPaths.flatMap((pair: { beforePath: string; afterPath: string }) => [pair.beforePath, pair.afterPath]),
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
      location_checks: {},
      clip_path: clipPath,
      document_paths: documentPaths,
      before_after_paths: beforeAfterPaths,
      location_photo_paths: locationPhotoPaths,
    });
    if (error) throw error;

    const lines = applicationReviewLines({
      documents: documentPaths,
      beforeAfterPairs: beforeAfterPaths.length,
      locationPhotoCount: locationPhotoPaths.length,
    });
    const message = `${first} ${last} applied to coach at ONE Fitness.\n\nEmail: ${email}\nPhone: ${phone}\nLocation: ${locationName}\n\nUploads:\n${lines.join("\n")}\n\nOpen the app, then Requests, to approve or deny it.`;
    const pairs = [];
    for (const pair of beforeAfterPaths) {
      const before = await admin.storage.from("coach-applications").createSignedUrl(pair.beforePath, 60 * 60 * 24 * 7);
      const after = await admin.storage.from("coach-applications").createSignedUrl(pair.afterPath, 60 * 60 * 24 * 7);
      if (before.data?.signedUrl && after.data?.signedUrl) {
        pairs.push({ beforeUrl: before.data.signedUrl, afterUrl: after.data.signedUrl });
      }
    }
    await emailOwners(admin, "New coach application", message, applicationEmailHtml(message, pairs));

    return json({ ok: true });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("finish-coach-application failed:", message);
    return json({ error: message }, 400);
  }
});
