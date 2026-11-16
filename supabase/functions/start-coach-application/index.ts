// Starts an Apply now form. Returns short-lived upload links for the private
// coach-applications bucket. No account is created. Proposed. Not deployed
// until you deploy this function. The gateway accepts the app's anon key
// because the person is not signed in yet.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

const MAX_FILES = 30;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const body = await req.json();
    const email = String(body.email ?? "").trim().toLowerCase();
    if (!email.includes("@") || email.length > 200) throw new Error("Enter a real email address.");
    const files = Array.isArray(body.files) ? body.files : [];
    if (files.length > MAX_FILES) throw new Error("That's too many files.");

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { count } = await admin.from("coach_applications").select("id", { count: "exact", head: true }).eq("email", email).gte("created_at", since);
    if ((count ?? 0) >= 3) throw new Error("That email already sent an application recently. Wait a day, or write to ONE Fitness.");

    const applicationId = crypto.randomUUID();
    const uploads = [];
    let docs = 0;
    let photos = 0;
    let befores = 0;
    let clip = 0;
    for (const file of files) {
      const key = String(file.key ?? "");
      const contentType = String(file.contentType ?? "application/octet-stream");
      let path = "";
      if (key === "clip") {
        clip += 1;
        if (clip > 1) throw new Error("Only one coaching clip.");
        path = `${applicationId}/clip.m4a`;
      } else if (key.startsWith("doc-")) {
        docs += 1;
        if (docs > 12) throw new Error("You can attach up to 12 documents.");
        path = `${applicationId}/docs/${key}`;
      } else if (key.startsWith("before-") || key.startsWith("after-")) {
        befores += 1;
        if (befores > 12) throw new Error("You can attach up to 12 before-and-after photos.");
        path = `${applicationId}/before-after/${key}.jpg`;
      } else if (key.startsWith("location-")) {
        photos += 1;
        if (photos > 8) throw new Error("You can attach up to 8 location photos.");
        path = `${applicationId}/location/${key}.jpg`;
      } else {
        throw new Error("That file isn't part of the application.");
      }
      const { data, error } = await admin.storage.from("coach-applications").createSignedUploadUrl(path);
      if (error || !data) throw new Error(error?.message ?? "Couldn't prepare the upload.");
      uploads.push({ key, path, token: data.token, signedUrl: data.signedUrl, contentType });
    }

    return json({ applicationId, uploads });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("start-coach-application failed:", message);
    return json({ error: message }, 400);
  }
});
