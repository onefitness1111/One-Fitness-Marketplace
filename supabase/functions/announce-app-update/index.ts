// A one-time phone alert that the app has been updated.
//
// Only the owner can call this, and only by tapping Send. Nothing here
// runs on a timer. Deploy with the login check left on:
//   supabase functions deploy announce-app-update
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { sendPush } from "../_shared/sendPush.ts";
import { CORS_HEADERS, clip, json, requireStaff } from "../_shared/messagingGuard.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const { admin, role } = await requireStaff(req);
    if (role !== "owner") throw new Error("Only the owner can announce an update.");
    const body = await req.json();
    const title = clip(body.title ?? "ONE Fitness", 120, "Title");
    const text = clip(
      body.text ?? "The ONE Fitness app has been updated with lots of new features. Update now.",
      500,
      "Message",
    );
    const { data: rows, error } = await admin.from("device_tokens").select("token");
    if (error) throw new Error("Couldn't load phones to notify.");
    const tokens = [...new Set((rows ?? []).map((row: { token?: string }) => String(row.token ?? "").trim()).filter(Boolean))];
    await sendPush(tokens, title, text, { kind: "app-update" });
    return json({ ok: true, sent: tokens.length });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("announce-app-update failed:", message);
    return json({ error: message }, 400);
  }
});
