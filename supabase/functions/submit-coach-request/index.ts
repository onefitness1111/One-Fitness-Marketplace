// A coach files a request. The row is written by submit_coach_request.
// The owner gets a push. Proposed. Not deployed until you deploy this function.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { pushOwners } from "../_shared/requestNotify.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

const KIND_LABEL: Record<string, string> = {
  freeze_membership: "freeze a membership",
  unfreeze_membership: "end a freeze",
  restrict_client: "restrict a client",
  lift_restriction: "lift a restriction",
  extra_free_session: "add an extra free session",
  adjust_balance: "change a balance",
  delete_client: "delete a client",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const body = await req.json();
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data, error } = await userClient.rpc("submit_coach_request", {
      p_kind: body.kind,
      p_client: body.clientId,
      p_reason: body.reason ?? "",
      p_payload: body.payload ?? {},
    });
    if (error) throw new Error(error.message);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: client } = await admin.from("profiles").select("name").eq("id", body.clientId).maybeSingle();
    const label = KIND_LABEL[String(body.kind)] ?? "a change";
    const who = client?.name ? ` for ${client.name}` : "";
    await pushOwners(admin, "A coach request is waiting", `A coach asked to ${label}${who}. Open Requests to approve or deny it.`);

    return json({ ok: true, id: data?.id });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("submit-coach-request failed:", message);
    return json({ error: message }, 400);
  }
});
