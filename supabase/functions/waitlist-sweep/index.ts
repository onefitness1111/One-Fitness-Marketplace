// Runs every 15 minutes from pg_cron (see migration/02_waitlist_cascade.sql).
// Walks every future slot that has anyone waiting or holding an offer and
// lets offerSlot do its work: expire offers past their four-hour window and,
// once two hours have passed since the newest live offer, send the next
// person theirs. Without this, the cascade could only advance when someone
// happened to tap Decline.
//
// Deployed --no-verify-jwt — cron carries no user session — and gated by the
// timer's x-cron-secret (Vault secret via cron_vault_secret(); the older
// CRON_SECRET is still accepted). Texts it causes wait for 8:00am during
// quiet hours (sendAutoSms).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isCronRequest } from "../_shared/cronAuth.ts";
import { pacificDate } from "../_shared/quietHours.mjs";
import { offerSlot } from "../_shared/waitlistOffers.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

serve(async (req) => {
  if (!(await isCronRequest(admin, req))) {
    return new Response("Forbidden", { status: 403 });
  }

  try {
    const today = pacificDate(new Date());
    const { data: rows } = await admin.from("waitlist")
      .select("trainer_id, date, slot")
      .in("status", ["waiting", "offered"])
      .gte("date", today);

    const slots = new Map<string, { trainerId: string; date: string; slot: number }>();
    for (const r of rows ?? []) {
      const key = `${r.trainer_id}|${r.date}|${r.slot}`;
      if (!slots.has(key)) slots.set(key, { trainerId: r.trainer_id as string, date: r.date as string, slot: Number(r.slot) });
    }

    let offered = 0;
    for (const s of slots.values()) {
      try {
        if (await offerSlot(s.trainerId, s.date, s.slot)) offered++;
      } catch (e) {
        console.error(`waitlist-sweep: ${s.trainerId} ${s.date} ${s.slot} failed:`, e instanceof Error ? e.message : String(e));
      }
    }

    console.log(`waitlist-sweep: ${slots.size} slot(s) checked, ${offered} new offer(s)`);
    return new Response(JSON.stringify({ ok: true, slots: slots.size, offered }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("waitlist-sweep failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
