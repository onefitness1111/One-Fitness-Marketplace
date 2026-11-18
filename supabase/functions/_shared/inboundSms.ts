// Inbound SMS to the business number.
//
// STOP, UNSUBSCRIBE and HELP are handled here. A normal text is routed by
// chatRouting.mjs: a @CoachName tag, then the conversation that is still
// inside 6 hours, then Business Chat. There is no menu of reply codes.
//
// Deploy WITHOUT jwt verification. Twilio sends no JWT. The request is
// checked with Twilio's signature instead.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { ThreadBook } from "./chatRouting.mjs";
import { BUSINESS_NAME, markOptIn, markOptOut, toE164 } from "./chatPeople.ts";
import { sendSms } from "./sendSms.ts";
import { describeWebhookUrl, twilioSignatureMatches, webhookCandidates } from "./twilioWebhookUrl.ts";

function twiml(message?: string | null): Response {
  const body = message
    ? `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeXml(message)}</Message></Response>`
    : `<?xml version="1.0" encoding="UTF-8"?><Response></Response>`;
  return new Response(body, { headers: { "Content-Type": "text/xml" } });
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function pairKey(a: string, b: string): string {
  return [a, b].sort().join("|");
}

// deno-lint-ignore no-explicit-any
function rowFor(message: any, people: Map<string, any>) {
  const [aId, bId] = String(message.conversationKey).split("|");
  const a = people.get(aId);
  const b = people.get(bId);
  const sender = people.get(message.senderId);
  const pair = [a, b].filter(Boolean);
  const owner = pair.find((p) => p.role === "owner");
  const client = pair.find((p) => p.role === "client");
  const coaches = pair.filter((p) => p.role === "coach");
  let clientId: string;
  let trainerId: string | null;
  if (owner) {
    const member = pair.find((p) => p.id !== owner.id);
    clientId = member.id;
    trainerId = null;
  } else if (client && coaches.length >= 1) {
    clientId = client.id;
    trainerId = coaches[0].id;
  } else {
    const other = sender.id === a.id ? b : a;
    clientId = other.id;
    trainerId = sender.role === "coach" ? sender.id : null;
  }
  const who = sender.role === "client" ? "client" : "trainer";
  return {
    client_id: clientId,
    trainer_id: trainerId,
    sender_id: sender.id,
    who,
    body: message.raw,
    channel: "sms",
    read_by_coach: who !== "client",
  };
}

export async function handleInbound(req: Request): Promise<Response> {
  try {
    if (req.method !== "POST") return twiml();

    const raw = await req.text();
    const params: Record<string, string> = {};
    for (const [k, v] of new URLSearchParams(raw)) params[k] = v;

    const override = Deno.env.get("TWILIO_WEBHOOK_URL") ?? null;
    const candidates = webhookCandidates({
      requestUrl: req.url,
      forwardedHost: req.headers.get("x-forwarded-host"),
      host: req.headers.get("host"),
      override,
      supabaseUrl: Deno.env.get("SUPABASE_URL") ?? null,
    });
    const signature = req.headers.get("x-twilio-signature") ?? "";
    const token = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
    let matched: string | null = null;
    for (const url of candidates) {
      if (await twilioSignatureMatches(token, url, params, signature)) {
        matched = url;
        break;
      }
    }
    if (!matched) {
      console.warn(`sms-inbound: signature matched none of ${candidates.length} candidates`);
      return new Response("Forbidden", { status: 403 });
    }
    console.log(`sms-inbound: signature matched ${describeWebhookUrl(matched, override)}`);

    const from = params["From"] ?? "";
    const text = (params["Body"] ?? "").trim();
    if (!from || !text) return twiml();

    const admin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: fromId, error: whoErr } = await admin.rpc("profile_id_for_sms", { raw_phone: from });
    if (whoErr) throw whoErr;

    const { data: profiles, error: profileErr } = await admin
      .from("profiles")
      .select("id, role, name, phone, sms_opted_out, sms_consent_at")
      .is("deleted_at", null);
    if (profileErr) throw profileErr;

    const { data: clientRows } = await admin.from("clients").select("profile_id, sms_opt_in");
    const optedIn = new Set(
      (clientRows ?? []).filter((row: { sms_opt_in?: boolean }) => row.sms_opt_in === true).map((row: { profile_id: string }) => row.profile_id),
    );

    const people = new Map<string, {
      id: string;
      role: string;
      displayName: string;
      coachName: string;
      phone: string;
      optedOut: boolean;
      hasConsent: boolean;
    }>();

    for (const profile of profiles ?? []) {
      const id = profile.id as string;
      const role = String(profile.role || "");
      let displayName = String(profile.name || "").trim() || "Client";
      let coachName = "";
      if (role === "owner") {
        displayName = BUSINESS_NAME;
      } else if (role === "coach") {
        const { data: pub } = await admin.rpc("coach_public_name", { p_id: id });
        displayName = String(pub || "").trim() || "Coach";
        coachName = displayName;
      }
      people.set(id, {
        id,
        role,
        displayName,
        coachName,
        phone: String(profile.phone || "").trim(),
        optedOut: profile.sms_opted_out === true,
        hasConsent: profile.sms_consent_at != null || optedIn.has(id),
      });
    }

    const book = new ThreadBook([...people.values()]);

    const { data: convos } = await admin.from("conversations").select("id, participant_a, participant_b, last_activity_at");
    const ownerIds = new Set([...people.values()].filter((p) => p.role === "owner").map((p) => p.id));
    const keyByConversation = new Map<string, string>();
    const seededConvos = [];
    for (const convo of convos ?? []) {
      const key = pairKey(convo.participant_a as string, convo.participant_b as string);
      keyByConversation.set(convo.id as string, key);
      seededConvos.push({
        key,
        a: convo.participant_a as string,
        b: convo.participant_b as string,
        lastActivityAt: convo.last_activity_at ? Date.parse(convo.last_activity_at as string) : null,
        routedTo: ownerIds.has(convo.participant_a as string) || ownerIds.has(convo.participant_b as string)
          ? "business"
          : "conversation",
      });
    }

    const { data: msgs } = await admin
      .from("messages")
      .select("id, body, sender_id, created_at, conversation_id, routed_to, origin_channel, direction")
      .order("created_at", { ascending: false })
      .limit(500);
    const seededMessages = [];
    for (const msg of msgs ?? []) {
      const key = keyByConversation.get(msg.conversation_id as string);
      if (!key) continue;
      seededMessages.push({
        id: msg.id as string,
        conversationKey: key,
        senderId: msg.sender_id as string,
        body: String(msg.body || ""),
        raw: String(msg.body || ""),
        at: Date.parse(msg.created_at as string),
        channel: (msg.origin_channel as string) || "app",
        direction: (msg.direction as string) || "outbound",
        routedTo: (msg.routed_to as string) || "conversation",
      });
    }
    book.seed({ conversations: seededConvos, messages: seededMessages });

    const beforeMessages = book.messages.length;
    const beforeLikes = book.likes.length;
    const result = book.receiveSms({
      fromId: (fromId as string | null) || null,
      text,
      now: Date.now(),
      phone: from,
    });

    if (result.kind === "stop" && fromId) await markOptOut(admin, fromId as string);
    if (result.kind === "start" && fromId) await markOptIn(admin, fromId as string);

    for (const message of book.messages.slice(beforeMessages)) {
      const row = rowFor(message, people);
      const { error: insertErr } = await admin.from("messages").insert(row);
      if (insertErr) {
        console.warn(`sms-inbound: message not stored: ${insertErr.message}`);
        continue;
      }
      // A coach is not on the client list, so a text that lands in Business
      // Chat would be saved but easy to miss. Copy it into the business
      // inbox the owner already reads. The name on it is the coach name.
      const member = people.get(row.client_id);
      if (row.trainer_id == null && member && member.role !== "client") {
        await admin.from("staff_messages").insert({
          sender_id: row.sender_id,
          recipient_id: null,
          body: message.body,
          channel: "sms",
        });
      }
    }

    for (const like of book.likes.slice(beforeLikes)) {
      if (!/^[0-9a-f-]{36}$/i.test(like.messageId)) continue;
      const { data: parent } = await admin.from("messages").select("client_id, routed_to").eq("id", like.messageId).maybeSingle();
      const { error: likeErr } = await admin.from("message_reactions").upsert({
        message_id: like.messageId,
        user_id: like.userId,
        client_id: parent?.client_id ?? null,
        reaction: like.reaction,
        source: "sms_tapback",
        channel: "sms",
        direction: "inbound",
        routed_to: parent?.routed_to || like.routedTo || "conversation",
      }, { onConflict: "message_id,user_id" });
      if (likeErr) console.warn(`sms-inbound: like not stored: ${likeErr.message}`);
    }

    if (result.kind === "lead" || (result.kind === "business" && book.messages.length === beforeMessages)) {
      await admin.from("lead_sms").insert({
        phone: from,
        sender_id: (fromId as string | null) || null,
        body: text,
        kind: result.kind === "lead" ? "lead" : "business",
      });
    }
    if (result.kind === "stop" || result.kind === "help" || result.kind === "start") {
      await admin.from("lead_sms").insert({
        phone: from,
        sender_id: (fromId as string | null) || null,
        body: text,
        kind: result.kind,
      });
    }

    // A saved message is texted by the database trigger, so the outbox is
    // only used when there is no message row (an unknown number).
    if (result.kind === "lead") {
      for (const item of result.sms ?? []) {
        const owner = people.get(item.toId);
        const to = owner ? toE164(owner.phone) : null;
        if (to) await sendSms(to, item.body);
      }
    }

    console.log(`sms-inbound: ${result.kind} from ${fromId ? "member" : "unknown"}`);
    return twiml(result.twiml ?? null);
  } catch (e) {
    console.error("sms-inbound failed:", e instanceof Error ? e.message : String(e));
    return twiml();
  }
}
