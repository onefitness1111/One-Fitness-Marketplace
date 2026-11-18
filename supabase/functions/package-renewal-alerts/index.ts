// Package renewal reminders.
//
// Proposed. Not deployed until you deploy this function.
// A timer calls it at 9:05am Pacific with the header x-cron-secret set to
// the Vault secret apply_requests_cron (the same secret the freeze job uses).
// A signed-in client can call it for themselves, which is how the reminder
// shows up in the app. The password is not stored in this file.
//
// 8 sessions left: "Renew now at 5% off." 2 left: full price.
// Each reminder is sent once. The numbers match packageRenewal.ts and
// lib/core/utils/package_renewal.dart.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyProfile } from "../_shared/requestNotify.ts";
import {
  effectivePackageMax,
  renewalDiscountCents,
  renewalOffer,
} from "../_shared/packageRenewal.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

function pacificMonth(): string {
  const iso = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit" }).format(new Date());
  return iso.slice(0, 7);
}

// deno-lint-ignore no-explicit-any
function activePackages(plansJson: unknown, planById: Map<string, any>) {
  const list = Array.isArray(plansJson) ? plansJson : [];
  const active = list.filter((e) => e && e.status === "active" && e.planId);
  active.sort((a, b) => String(a.startDate || "").localeCompare(String(b.startDate || "")));
  const seen = new Set<string>();
  const out: { planId: string; start: string; plan: Record<string, unknown> }[] = [];
  for (const e of active) {
    const planId = String(e.planId);
    const plan = planById.get(planId);
    if (!plan || plan.kind !== "package" || plan.archived) continue;
    if (seen.has(planId)) continue;
    const start = String(e.startDate || "").slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) continue;
    seen.add(planId);
    out.push({ planId, start, plan });
  }
  return out;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const admin = createClient(url, serviceKey);

    const cron = req.headers.get("x-cron-secret");
    const { data: secretRow, error: secretErr } = await admin.rpc("cron_vault_secret");
    if (secretErr) console.error("cron vault read failed");
    const expected = typeof secretRow === "string" ? secretRow : "";
    const cronOk = expected.length > 0 && cron === expected;

    let onlyClient: string | null = null;
    if (!cronOk) {
      const authed = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await authed.auth.getUser();
      if (!user) throw new Error("Not signed in.");
      const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (profile?.role === "client") onlyClient = user.id;
      else if (profile?.role !== "owner") throw new Error("Not allowed.");
    }

    let clientQuery = admin.from("clients").select("profile_id, plans, session_count_override, session_count_override_month");
    if (onlyClient) clientQuery = clientQuery.eq("profile_id", onlyClient);
    const { data: clientRows, error: clientErr } = await clientQuery;
    if (clientErr) throw clientErr;

    const { data: planRows, error: planErr } = await admin.from("membership_plans").select("id, data");
    if (planErr) throw planErr;
    // deno-lint-ignore no-explicit-any
    const planById = new Map<string, any>();
    for (const row of planRows || []) {
      if (row?.id && row.data) planById.set(String(row.id), row.data);
    }

    const ids = (clientRows || []).map((c: { profile_id: string }) => c.profile_id).filter(Boolean);
    if (ids.length === 0) {
      return new Response(JSON.stringify({ ok: true, sent: 0, offers: [] }), {
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    const { data: bookingRows, error: bookingErr } = await admin
      .from("bookings")
      .select("client_id, plan_id, attendance_status, is_physical_assessment")
      .in("client_id", ids)
      .in("attendance_status", ["checked-in", "no-show"])
      .is("cancelled_at", null);
    if (bookingErr) throw bookingErr;

    const used = new Map<string, number>();
    for (const b of bookingRows || []) {
      if (b.is_physical_assessment) continue;
      const planId = String(b.plan_id || "");
      if (!planId || planId.startsWith("single:")) continue;
      const key = `${b.client_id}|${planId}`;
      used.set(key, (used.get(key) || 0) + 1);
    }

    const { data: noticeRows, error: noticeErr } = await admin
      .from("client_notices")
      .select("client_id, kind, plan_id, enrollment_start, forfeited, dismissed_at")
      .in("client_id", ids)
      .in("kind", ["package_discount", "package_full"]);
    if (noticeErr) throw noticeErr;

    const { data: paidRows, error: paidErr } = await admin
      .from("package_renewal_charges")
      .select("client_id, plan_id, enrollment_start")
      .in("client_id", ids)
      .eq("status", "succeeded");
    if (paidErr) throw paidErr;

    const month = pacificMonth();
    let sent = 0;
    const offers: Record<string, unknown>[] = [];

    for (const client of clientRows || []) {
      const clientId = String(client.profile_id || "");
      if (!clientId) continue;
      const override = client.session_count_override == null ? null : Number(client.session_count_override);
      for (const held of activePackages(client.plans, planById)) {
        const max = effectivePackageMax(held.plan, override, client.session_count_override_month ?? null, month);
        const remaining = Math.max(0, max - (used.get(`${clientId}|${held.planId}`) || 0));
        const price = Number(held.plan.priceCents || 0);
        const notices = (noticeRows || []).filter((n: {
          client_id: string;
          plan_id: string;
          enrollment_start: string;
        }) => n.client_id === clientId && n.plan_id === held.planId && String(n.enrollment_start || "").slice(0, 10) === held.start);
        const forfeited = notices.some((n: { kind: string; forfeited: boolean }) => n.kind === "package_discount" && n.forfeited);
        const already = (paidRows || []).some((p: { client_id: string; plan_id: string; enrollment_start: string }) =>
          p.client_id === clientId && p.plan_id === held.planId && String(p.enrollment_start || "").slice(0, 10) === held.start
        );
        const offer = renewalOffer(remaining, max, price, forfeited, already);
        if (offer === "none") continue;

        const kind = offer === "discount" ? "package_discount" : "package_full";
        const existing = notices.find((n: { kind: string }) => n.kind === kind);
        const name = String(held.plan.name || "package");
        const off = offer === "discount" ? renewalDiscountCents(price) : 0;
        const title = offer === "discount" ? "Renew now at 5% off" : "Renew now";
        const body = offer === "discount"
          ? `Your ${name} has ${remaining} sessions left. Renew now and the price is 5% off. If you skip this, that discount is gone for this package.`
          : `Your ${name} has ${remaining} sessions left. Renew now to keep your sessions going.`;

        if (!existing) {
          const { error: insertErr } = await admin.from("client_notices").insert({
            client_id: clientId,
            kind,
            plan_id: held.planId,
            enrollment_start: held.start,
            title,
            body,
            forfeited: false,
          });
          if (insertErr && insertErr.code !== "23505") {
            console.error("renewal notice insert failed");
            continue;
          }
          if (!insertErr) {
            await notifyProfile(admin, clientId, title, body, false);
            sent += 1;
          }
        }

        const dismissed = existing && existing.dismissed_at;
        if (!dismissed && (onlyClient === clientId || (!onlyClient && cronOk))) {
          // The app only reads offers for the signed-in client. The timer
          // does not need them in the response.
          if (onlyClient === clientId) {
            offers.push({
              planId: held.planId,
              planName: name,
              enrollmentStart: held.start,
              offer,
              remaining,
              priceCents: price,
              chargeCents: price - off,
            });
          }
        }
      }
    }

    return new Response(JSON.stringify({ ok: true, sent, offers: onlyClient ? offers : [] }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Could not check package renewals.";
    console.error("package-renewal-alerts failed");
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
