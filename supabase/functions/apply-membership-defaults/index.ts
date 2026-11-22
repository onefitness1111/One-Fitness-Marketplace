// Push a membership's session count and rollover limit onto everyone on it.
//
// Proposed. Not deployed until you deploy this function.
// Owner only. Coaches cannot edit memberships, so they cannot do this either.
// Personal overrides for this one plan are cleared. Other plans, and other
// clients, are left alone. Calling it twice is the same as calling it once.
// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { clearPlanOverrides, clientIsActiveOnPlan } from "../_shared/membershipRollover.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PAGE = 1000;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { planId } = await req.json();
    if (!planId || typeof planId !== "string") throw new Error("Choose a membership first.");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await authed.auth.getUser();
    if (!user) throw new Error("Not signed in.");

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (profile?.role !== "owner") {
      throw new Error("Only the owner can apply a membership to everyone on it.");
    }

    const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", planId).maybeSingle();
    if (!planRow?.data) throw new Error("Membership not found.");
    if (planRow.data.kind !== "membership") {
      throw new Error("This applies to memberships. Packages keep the count they were bought with.");
    }

    const clients: any[] = [];
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await admin.from("clients")
        .select("profile_id, plans, membership_plan_id, session_count_override")
        .range(from, from + PAGE - 1);
      if (error) throw new Error("Couldn't read who is on this membership.");
      clients.push(...(data || []));
      if (!data || data.length < PAGE) break;
    }

    let affected = 0;
    for (const client of clients) {
      const plans = Array.isArray(client.plans) ? client.plans : [];
      const onIt = clientIsActiveOnPlan(
        { membershipPlanId: client.membership_plan_id, plans },
        planId,
      );
      if (!onIt) continue;
      affected += 1;
      const next = clearPlanOverrides(plans, planId);
      const plansChanged = JSON.stringify(next) !== JSON.stringify(plans);
      const clearLegacy = client.membership_plan_id === planId && client.session_count_override != null;
      if (!plansChanged && !clearLegacy) continue;
      const patch: Record<string, unknown> = {};
      if (plansChanged) patch.plans = next;
      if (clearLegacy) {
        patch.session_count_override = null;
        patch.session_count_override_month = null;
      }
      const { error } = await admin.from("clients").update(patch).eq("profile_id", client.profile_id);
      if (error) throw new Error("Couldn't update everyone on this membership.");
    }

    return new Response(JSON.stringify({ ok: true, affected }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Couldn't apply this membership.";
    console.error("apply-membership-defaults failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
