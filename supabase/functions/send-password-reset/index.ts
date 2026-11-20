// Sends a password-reset email without handing the address back to the app.
//
// Proposed replacement. Not deployed until you deploy this function.
// A coach can do this for a client. The owner can do it for a client or a
// coach. The email address stays on the server.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import {
  CORS_HEADERS,
  json,
  memberById,
  requireStaff,
} from "../_shared/messagingGuard.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const { profileId } = await req.json();
    const id = String(profileId ?? "").trim();
    if (!id) throw new Error("Choose an account first.");

    const { admin, role } = await requireStaff(req);
    const member = await memberById(admin, id);
    if (!member) throw new Error("That account no longer exists.");
    if (role === "coach" && member.role !== "client") {
      throw new Error("A coach can send a reset link for a client only.");
    }
    if (role === "owner" && member.role !== "client" && member.role !== "coach") {
      throw new Error("That account can't be reset from here.");
    }
    if (!member.email) throw new Error("This account has no email address, so a reset link can't be sent.");

    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const res = await fetch(`${url}/auth/v1/recover`, {
      method: "POST",
      headers: {
        apikey: anon,
        Authorization: `Bearer ${anon}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email: member.email,
        redirect_to: "onefitness://reset-password",
      }),
    });
    if (!res.ok) {
      const detail = await res.text();
      console.error(`send-password-reset: recover ${res.status}: ${detail}`);
      throw new Error("Couldn't send the reset email. Try again in a minute.");
    }

    console.log(`send-password-reset: ${role} reset ${member.id} (${member.role})`);
    return json({ ok: true });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("send-password-reset failed:", message);
    return json({ error: message }, 400);
  }
});
