// Enrolls someone in a plan that does not need a card charge.
//
// Proposed replacement. Not deployed until you deploy this function.
// A plan whose price is above zero can be given away only by the owner.
// A coach can still assign a plan that is actually free. Clients can still
// enroll themselves in a free plan.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { assertPlanContractSigned } from "../_shared/planContract.ts";
import { assertPlanOnSale } from "../_shared/planSalesWindow.ts";
import { assertPlanPurchasable } from "../_shared/planVisibility.mjs";
import { nextPlanEnrollments } from "../_shared/membershipRollover.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { planId, clientId, accessExpiresAt } = await req.json();
    if (!planId) throw new Error("planId is required");

    const authedClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    let targetId = user.id;
    let callerIsStaff = false;
    let callerRole = "";
    {
      const { data: caller } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      callerRole = caller?.role ?? "";
      callerIsStaff = callerRole === "owner" || callerRole === "coach";
    }
    if (clientId && clientId !== user.id) {
      if (!callerIsStaff) throw new Error("Only a coach or owner can enroll another client.");
      targetId = clientId;
    }
    if (accessExpiresAt != null && !callerIsStaff) {
      throw new Error("Only a coach or owner can set an expiry date.");
    }

    const { data: planRow } = await admin.from("membership_plans").select("data").eq("id", planId).maybeSingle();
    const plan = planRow?.data;
    if (!plan) throw new Error("Plan not found.");
    assertPlanPurchasable(plan, { staffEnrollingClient: callerIsStaff && targetId !== user.id });
    assertPlanOnSale(plan);
    if ((plan.priceCents || 0) > 0 && callerRole !== "owner") {
      throw new Error("Only the owner can give a paid plan away for free. Coaches charge the plan's set price.");
    }
    await assertPlanContractSigned(admin, targetId, planId, {
      staffPurchasingForClient: callerIsStaff && targetId !== user.id,
    });

    const { data: existing } = await admin.from("clients")
      .select("plans, membership_plan_id, session_count_override, session_count_override_month")
      .eq("profile_id", targetId).maybeSingle();
    const enrollments = Array.isArray(existing?.plans) ? existing!.plans : [];
    const today = new Date().toISOString().slice(0, 10);
    // A new entry carries no session override and no rollover. A leftover
    // client-wide override stays on the plan that was already in the slot.
    const next = nextPlanEnrollments({
      plans: enrollments,
      membershipPlanId: existing?.membership_plan_id ?? null,
      sessionCountOverride: existing?.session_count_override ?? null,
      sessionCountOverrideMonth: existing?.session_count_override_month ?? null,
      planId,
      today,
      termMonths: plan.termMonths ?? null,
      endsAt: accessExpiresAt ? String(accessExpiresAt) : null,
    });

    const isProgram = plan.kind === "program" || plan.kind === "nutritionProgram";
    const takesSlot = !isProgram && (plan.kind === "membership" || !existing?.membership_plan_id);

    const { data: updated, error: updateErr } = await admin.from("clients").update({
      plans: next.plans,
      ...(takesSlot ? { membership_plan_id: planId } : {}),
      ...(next.clearLegacy ? { session_count_override: null, session_count_override_month: null } : {}),
    }).eq("profile_id", targetId).select("profile_id");
    if (updateErr) throw updateErr;
    if (!updated || updated.length === 0) {
      throw new Error("Your account isn't fully set up yet — please contact your coach.");
    }

    return new Response(JSON.stringify({ ok: true, isProgram }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("enroll-free-plan failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
