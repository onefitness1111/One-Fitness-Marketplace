// The owner approves or denies a coach application and the applicant is
// emailed. An approval includes the current coach code when it is still
// unused, so they can finish sign-up. Proposed. Not deployed until you
// deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "../_shared/sendEmail.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const body = await req.json();
    const id = String(body.id ?? "");
    const approve = body.approve === true;
    const note = String(body.note ?? "").trim();

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (caller?.role !== "owner") throw new Error("Only the owner can decide an application.");

    const { data: app, error } = await admin.from("coach_applications").select("*").eq("id", id).maybeSingle();
    if (error) throw error;
    if (!app) throw new Error("That application was not found.");
    if (app.status !== "pending") throw new Error("This application was already decided.");

    const { error: updateErr } = await admin.from("coach_applications").update({
      status: approve ? "approved" : "denied",
      decided_by: user.id,
      decided_at: new Date().toISOString(),
      decision_note: note || null,
    }).eq("id", id);
    if (updateErr) throw updateErr;

    const name = `${app.first_name}`.trim() || "there";
    if (!approve) {
      await sendEmail(
        app.email,
        "Your ONE Fitness coach application",
        `Hi ${name},\n\nThank you for applying. We won't be moving ahead with the application right now.\n\n— ONE Fitness`,
      );
      return json({ ok: true, codeSent: false });
    }

    const { data: codeRow } = await admin.from("coach_approval_code").select("code, used_at, expires_at").eq("id", true).maybeSingle();
    const code = String(codeRow?.code ?? "");
    const used = codeRow?.used_at != null;
    const expired = codeRow?.expires_at && String(codeRow.expires_at) < new Date().toISOString().slice(0, 10);
    let codeSent = false;
    let extra = "We will send you the coach code separately. Use it on the coach sign-up screen.";
    if (code && !used && !expired) {
      codeSent = true;
      extra = `Your coach code is ${code}. On the coach sign-up screen, choose "I have a code" and enter it. The code works once.`;
    } else if (used || expired) {
      extra = "The current coach code has already been used or has expired. ONE Fitness will generate a new one and send it to you.";
    }

    await sendEmail(
      app.email,
      "You're approved to coach at ONE Fitness",
      `Hi ${name},\n\nYour application is approved.\n\n${extra}\n\n— ONE Fitness`,
    );

    return json({ ok: true, codeSent });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("decide-coach-application failed:", message);
    return json({ error: message }, 400);
  }
});
