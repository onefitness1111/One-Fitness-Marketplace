// The Welcome automation email, rendered from the owner-editable template in
// public.email_templates ("welcome"). Called by the app right after a client's
// profile is created (their own signup, or a coach adding them). Only that
// client, or staff, can trigger it, and it only ever goes to that profile's
// own email address.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendHtmlEmailOrThrow } from "../_shared/sendEmail.ts";
import { businessName, loadTemplate, renderEmail } from "../_shared/emailTemplates.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) return json({ error: "Not signed in." }, 401);

    const { toEmail } = await req.json().catch(() => ({}));
    if (!toEmail || typeof toEmail !== "string") return json({ error: "toEmail is required" }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: target } = await admin.from("profiles").select("id, name, email").ilike("email", toEmail.trim()).maybeSingle();
    if (!target) return json({ error: "No account with that email." }, 404);

    if (target.id !== user.id) {
      const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (me?.role !== "owner" && me?.role !== "coach") return json({ error: "Not allowed." }, 403);
    }

    const template = await loadTemplate(admin, "welcome");
    if (!template || !template.enabled) return json({ sent: false, reason: "disabled" });

    const business = await businessName(admin);
    const first = ((target.name as string) || "").trim().split(/\s+/)[0] || "there";
    const { subject, html } = renderEmail({
      template,
      business,
      vars: { client_first_name: first, business_name: business },
    });
    await sendHtmlEmailOrThrow(target.email as string, subject, html);
    return json({ sent: true });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-welcome-email failed:", message);
    return json({ error: message }, 400);
  }
});
