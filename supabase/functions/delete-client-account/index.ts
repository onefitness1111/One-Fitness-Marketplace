// Fully deletes a client. Proposed replacement — not deployed until you
// deploy this function. The only behavior change: only the owner may call it.
// A coach cannot delete a client account.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { deleteAuthUser, authDeleteErrorMessage } from "../_shared/deleteAuthUser.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { clientId } = await req.json();
    if (!clientId) throw new Error("clientId is required");

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const authedClient = createClient(
      SUPABASE_URL,
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authedClient.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: callerProfile } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (!callerProfile || callerProfile.role !== "owner") {
      throw new Error("Only the owner can delete a client.");
    }

    const { data: targetProfile } = await admin.from("profiles").select("role, name").eq("id", clientId).maybeSingle();
    if (!targetProfile || targetProfile.role !== "client") throw new Error("That client no longer exists.");

    await admin.from("bookings").update({ cancelled_by: null }).eq("cancelled_by", clientId);
    await admin.from("platform_settings").update({ updated_by: null }).eq("updated_by", clientId);
    await admin.from("platform_settings_audit").update({ changed_by: null }).eq("changed_by", clientId);
    await admin.from("blocked_time").update({ created_by: null }).eq("created_by", clientId);
    await admin.from("points_ledger").update({ granted_by_user_id: null }).eq("granted_by_user_id", clientId);
    await admin.from("merit_badges").update({ granted_by_user_id: null }).eq("granted_by_user_id", clientId);
    await admin.from("merit_badges").update({ revoked_by_user_id: null }).eq("revoked_by_user_id", clientId);

    await admin.from("points_ledger").delete().eq("client_id", clientId);
    await admin.from("merit_badges").delete().eq("client_id", clientId);
    await admin.from("coach_pr_events").delete().eq("client_id", clientId);

    const { data: squads } = await admin.from("squads").select("id, lead_id, member_ids, member_meta");
    for (const squad of squads || []) {
      if (squad.lead_id === clientId) continue;
      const memberIds: string[] = squad.member_ids || [];
      if (!memberIds.includes(clientId)) continue;
      const memberMeta = { ...(squad.member_meta || {}) };
      delete memberMeta[clientId];
      await admin.from("squads").update({
        member_ids: memberIds.filter((id: string) => id !== clientId),
        member_meta: memberMeta,
      }).eq("id", squad.id);
    }
    const { data: challenges } = await admin.from("challenges").select("id, participants");
    for (const challenge of challenges || []) {
      const participants: string[] = challenge.participants || [];
      if (!participants.includes(clientId)) continue;
      await admin.from("challenges").update({
        participants: participants.filter((id: string) => id !== clientId),
      }).eq("id", challenge.id);
    }

    const delResult = await deleteAuthUser(admin, clientId, SUPABASE_URL, SERVICE_ROLE_KEY);
    if (!delResult.ok) throw new Error(authDeleteErrorMessage(delResult));

    console.log(`delete-client-account: owner ${user.id} fully deleted client ${clientId} (${targetProfile.name})`);
    return new Response(JSON.stringify({ ok: true }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("delete-client-account failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
