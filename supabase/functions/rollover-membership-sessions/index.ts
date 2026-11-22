// Month-end membership rollover.
//
// Proposed. Not deployed until you deploy this function.
// pg_cron calls it just after midnight Pacific on the 1st, with the header
// x-cron-secret set to the Vault secret apply_requests_cron. The owner can
// call it on the 1st as well. Any other day it does nothing, unless the
// owner passes { "force": true }.
//
// Unused sessions on each active membership (allowance minus check-ins and
// no-shows for that plan last month) roll into the new month, capped at that
// client's rollover limit. Running it twice in the same month does not add
// them again.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  applyMonthEndPlans,
  pacificCalendar,
  previousMonth,
} from "../_shared/membershipRollover.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const PAGE = 1000;

// deno-lint-ignore no-explicit-any
async function eachPage(build: () => any): Promise<any[]> {
  const rows: any[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await build().range(from, from + PAGE - 1);
    if (error) throw new Error("Couldn't read the rows for rollover.");
    rows.push(...(data || []));
    if (!data || data.length < PAGE) break;
  }
  return rows;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const admin = createClient(url, serviceKey);

    let body: { force?: boolean } = {};
    try {
      const parsed = await req.json();
      if (parsed && typeof parsed === "object") body = parsed;
    } catch {
      body = {};
    }

    const cron = req.headers.get("x-cron-secret");
    const { data: secretRow, error: secretErr } = await admin.rpc("cron_vault_secret");
    if (secretErr) console.error("cron vault read failed");
    const expected = typeof secretRow === "string" ? secretRow : "";
    const cronOk = expected.length > 0 && cron === expected;

    let owner = false;
    if (!cronOk) {
      const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await authed.auth.getUser();
      if (!user) throw new Error("Not signed in.");
      const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (profile?.role !== "owner") throw new Error("Only the owner can run the monthly rollover.");
      owner = true;
    }

    const pacific = pacificCalendar(new Date());
    if (pacific.day !== 1 && !(owner && body.force === true)) {
      return new Response(JSON.stringify({
        ok: true,
        skipped: true,
        reason: "Rollover runs on the 1st, Pacific time.",
      }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const newMonth = pacific.month;
    const prev = previousMonth(newMonth);

    const planRows = await eachPage(() => admin.from("membership_plans").select("id, data"));
    // deno-lint-ignore no-explicit-any
    const planById = new Map<string, any>();
    for (const row of planRows) {
      if (!row?.id) continue;
      planById.set(String(row.id), { id: row.id, ...(row.data || {}) });
    }

    const clients = await eachPage(() =>
      admin.from("clients").select("profile_id, plans, membership_plan_id, session_count_override, session_count_override_month")
    );
    const bookings = await eachPage(() =>
      admin.from("bookings")
        .select("client_id, plan_id, date, attendance_status, cancelled_at, is_physical_assessment")
        .gte("date", `${prev}-01`)
        .lt("date", `${newMonth}-01`)
        .in("attendance_status", ["checked-in", "no-show"])
        .is("cancelled_at", null)
    );

    const bookingsByClient = new Map<string, any[]>();
    for (const row of bookings) {
      if (!row?.client_id || row.is_physical_assessment) continue;
      const list = bookingsByClient.get(row.client_id) || [];
      list.push(row);
      bookingsByClient.set(row.client_id, list);
    }

    let updated = 0;
    for (const client of clients) {
      const plans = Array.isArray(client.plans) ? client.plans : [];
      if (plans.length === 0) continue;
      const legacyValue = client.session_count_override == null ? null : Number(client.session_count_override);
      const result = applyMonthEndPlans(
        plans,
        planById,
        bookingsByClient.get(client.profile_id) || [],
        newMonth,
        (planId: string) => {
          if (legacyValue == null || client.membership_plan_id !== planId) return null;
          return { applies: true, value: legacyValue, month: client.session_count_override_month ?? null };
        },
      );
      if (!result.changed) continue;
      const { error } = await admin.from("clients").update({ plans: result.plans }).eq("profile_id", client.profile_id);
      if (error) {
        console.error("rollover update failed", client.profile_id);
        throw new Error("Couldn't save rolled sessions.");
      }
      updated += 1;
    }

    return new Response(JSON.stringify({ ok: true, month: newMonth, updated }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Couldn't roll sessions over.";
    console.error("rollover-membership-sessions failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
