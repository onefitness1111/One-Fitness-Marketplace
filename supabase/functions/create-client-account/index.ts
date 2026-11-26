// Coach/owner creates a client account on their behalf — the in-person
// signup path, for someone standing at the desk who isn't going to install
// the app and register themselves first.
//
// Runs server-side because creating an auth user requires the GoTrue Admin
// API (service role), which can never be exposed to the app. Role is
// re-checked here rather than trusted from the caller.
//
// The account is created with a temporary password returned to the coach to
// hand over. A password-reset email would be tidier, but it depends on
// Supabase's own SMTP being configured — which it isn't here — so this keeps
// the flow working with what actually exists.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

/// Readable rather than maximally random: it gets read aloud or typed by
/// hand at least once, and the client is expected to change it. Still ~10^10
/// combinations, and it only has to survive until first sign-in.
function tempPassword(): string {
  const words = ["Squat", "Bench", "Lunge", "Press", "Rowing", "Plank", "Sprint", "Deadlift"];
  const word = words[Math.floor(Math.random() * words.length)];
  const digits = Math.floor(1000 + Math.random() * 9000);
  return `${word}${digits}!`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const {
      name, firstName, lastName, email, phone, city, birthday,
      password: chosenPassword, photo, coachCode, primaryTrainerId,
    } = await req.json();
    const cleanFirst = String(firstName ?? "").trim();
    const cleanLast = String(lastName ?? "").trim();
    // Same shape the client's own signup produces: split names stored
    // alongside the combined one, because every screen reads `name`.
    const cleanName = String(name ?? "").trim() || [cleanFirst, cleanLast].filter(Boolean).join(" ");
    const cleanEmail = String(email ?? "").trim().toLowerCase();
    if (!cleanName) throw new Error("A name is required.");
    if (!cleanEmail || !cleanEmail.includes("@")) throw new Error("A valid email address is required.");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (me?.role !== "owner" && me?.role !== "coach") {
      throw new Error("Only a coach or owner can add a client.");
    }

    // Checked before creating anything: GoTrue's own duplicate error is
    // opaque, and "that email already has an account" is what the coach
    // actually needs to hear.
    const { data: existing } = await admin.from("profiles").select("id").eq("email", cleanEmail).maybeSingle();
    if (existing) throw new Error("Someone with that email already has an account.");

    // The coach can set the password on the form (same page as self-signup);
    // otherwise one is generated for handover. Same floor as the app's own
    // signup screen enforces.
    const password = String(chosenPassword ?? "").length >= 6 ? String(chosenPassword) : tempPassword();

    // A coach code links the client to that coach, exactly as the client's
    // own signup does — a typo just means no link, never a failed account.
    let codeTrainerId: string | null = null;
    const cleanCode = String(coachCode ?? "").trim();
    if (cleanCode) {
      const { data: match } = await admin.from("trainers").select("profile_id").ilike("coach_code", cleanCode).maybeSingle();
      codeTrainerId = (match?.profile_id as string | undefined) ?? null;
    }

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: cleanEmail,
      password,
      // No confirmation round trip — the coach is vouching for them in
      // person, and an unconfirmed account couldn't sign in.
      email_confirm: true,
      user_metadata: { name: cleanName, requested_role: "client" },
    });
    if (createErr) throw createErr;
    const newId = created.user?.id;
    if (!newId) throw new Error("The account wasn't created — please try again.");

    // A profiles row may already exist via a signup trigger; upsert rather
    // than insert so this works either way.
    const { error: profileErr } = await admin.from("profiles").upsert({
      id: newId,
      name: cleanName,
      email: cleanEmail,
      // profiles.phone is NOT NULL (default ''). Writing null here was the
      // "[object Object]" failure every coach hit when they left phone
      // blank — the signup trigger uses '' for the same column.
      phone: String(phone ?? "").trim(),
      first_name: cleanFirst || null,
      last_name: cleanLast || null,
      // Data URL, same as every other profile photo in the app.
      ...(photo ? { photo_url: String(photo) } : {}),
      role: "client",
    });
    if (profileErr) throw profileErr;

    // trg_ensure_client_row creates this too, but doing it explicitly means
    // the city/coach fields land in the same write rather than needing a
    // second one.
    const { error: clientErr } = await admin.from("clients").upsert({
      profile_id: newId,
      city: String(city ?? "").trim() || null,
      birthday: String(birthday ?? "").trim() || null,
      // Precedence: an explicit pick, then a coach code, then — for a
      // coach adding someone — themselves. An owner with neither leaves
      // the client unassigned.
      primary_trainer_id: primaryTrainerId ?? codeTrainerId ?? (me.role === "coach" ? user.id : null),
      ...(codeTrainerId ? { referred_by_trainer_id: codeTrainerId } : {}),
    });
    if (clientErr) throw clientErr;

    await admin.from("client_records").upsert({
      profile_id: newId,
      data: { program: [], logs: [], comms: [] },
    });

    console.log(`create-client-account: ${user.id} created client ${newId}`);
    return new Response(
      JSON.stringify({ ok: true, clientId: newId, email: cleanEmail, tempPassword: password }),
      { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  } catch (e) {
    // A PostgrestError is a plain object, not an Error — String() on it
    // gives "[object Object]", which is what the coach was seeing instead
    // of the actual reason. Read .message off anything that has one.
    const message = e instanceof Error
      ? e.message
      : (typeof e === "object" && e !== null && "message" in e)
        ? String((e as { message: unknown }).message)
        : String(e);
    console.error("create-client-account failed:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
