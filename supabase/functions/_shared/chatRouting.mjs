// The messaging rules, in one place, with no database and no Twilio.
//
// The inbound text handler and the app-send texter both use these functions.
// test/chat_routing.test.mjs walks the scenarios Coach Chris asked for.
// Keep the wording of the business name identical to the app:
// "ONE Fitness Marketplace" (the prefix already stored on messages).

import {
  INVITE_SMS_BODY,
  INVITE_YES_CONFIRMATION,
  inviteConsentRecord,
  isInviteYes,
  staffClientSmsAction,
} from "./smsInvite.mjs";

export {
  INVITE_SMS_BODY,
  INVITE_SMS_VERSION,
  INVITE_YES_CONFIRMATION,
  inviteConsentRecord,
  inviteEligible,
  isInviteYes,
  smsInviteEnabledFlag,
  staffClientSmsAction,
} from "./smsInvite.mjs";

export const WINDOW_MS = 6 * 60 * 60 * 1000;

export const BUSINESS_NAME = "ONE Fitness Marketplace";

// This gym's own App Store page is not a link we can verify. A public
// "One Fitness" app belongs to a different company, so it is not used here.
// Replace APP_STORE_LINK before the lead text goes live.
export const APP_STORE_URL = "APP_STORE_LINK";
export const PLAY_STORE_URL = "GOOGLE_PLAY_LINK";

export const HELP_TEXT =
  "ONE Fitness: for help call (818) 223-7001 or email info@onefitnessworkout.com. " +
  "Reply STOP to unsubscribe. Msg & data rates may apply.";

const OPT_OUT = new Set(["STOP", "STOPALL", "CANCEL", "END", "QUIT", "UNSUBSCRIBE", "REVOKE", "OPTOUT"]);
const OPT_IN = new Set(["START", "UNSTOP", "JOIN"]);
const HELP = new Set(["HELP", "INFO"]);

export function coachNameKey(name) {
  const key = String(name || "").toLowerCase().replace(/\s+/g, "");
  return key || null;
}

/** Broadcast label for a saved message. Empty keeps the stored coach prefix. */
export function sanitizeBroadcastName(raw) {
  const cleaned = String(raw ?? "").replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim();
  if (!cleaned) return "";
  return cleaned.length <= 40 ? cleaned : cleaned.slice(0, 40).trimEnd();
}

export function prefixBody(displayName, text) {
  const name = String(displayName || "").trim();
  const body = String(text || "");
  if (!name) return body;
  const prefix = `${name}:`;
  if (body.trimStart().startsWith(prefix)) return body;
  const trimmed = body.trim();
  if (!trimmed) return `${name}:`;
  return `${name}: ${trimmed}`;
}

export function businessNotice(senderName) {
  const name = String(senderName || "").trim() || "Someone";
  return `New message from ${name} in ${BUSINESS_NAME}.`;
}

export function unknownSenderLabel(phone) {
  const digits = String(phone || "").replace(/\D/g, "");
  const tail = digits.slice(-4);
  return tail ? `a new number ending ${tail}` : "a new number";
}

export function leadReply() {
  return (
    "Hey, we see you're not a ONE Fitness client yet! Tap here to create your profile so we can help you further: " +
    `${APP_STORE_URL}\nGoogle Play: ${PLAY_STORE_URL}`
  );
}

export function windowOpen(lastActivityAt, now) {
  if (lastActivityAt == null) return false;
  const at = typeof lastActivityAt === "number" ? lastActivityAt : new Date(lastActivityAt).getTime();
  if (Number.isNaN(at)) return false;
  const age = now - at;
  return age >= 0 && age < WINDOW_MS;
}

/** Whole message is a keyword, ignoring spaces and punctuation. "Yes" is a reply, not an opt-in. */
export function keywordKind(body) {
  const keyword = String(body || "").trim().toUpperCase().replace(/[^A-Z]/g, "");
  if (!keyword) return null;
  if (HELP.has(keyword)) return "help";
  if (OPT_OUT.has(keyword)) return "stop";
  if (OPT_IN.has(keyword)) return "start";
  return null;
}

/**
 * @returns {{id: string, coachName: string} | null}
 * Clients are never candidates. An @ that matches nobody is ignored.
 * The longest coach name wins, so Coach Christina beats Coach Chris.
 */
export function matchCoachTag(body, coaches) {
  const list = (coaches || [])
    .filter((c) => c && c.role === "coach")
    .map((c) => ({ id: c.id, coachName: c.coachName || c.displayName || "", key: coachNameKey(c.coachName || c.displayName) }))
    .filter((c) => c.key)
    .sort((a, b) => b.key.length - a.key.length || a.key.localeCompare(b.key));
  const source = String(body || "");
  for (let i = 0; i < source.length; i++) {
    if (source[i] !== "@") continue;
    const after = coachNameKey(source.slice(i + 1));
    for (const coach of list) {
      if (after.startsWith(coach.key)) return { id: coach.id, coachName: coach.coachName };
    }
  }
  return null;
}

function personName(person) {
  return String(person?.displayName || person?.name || "").trim();
}

function firstToken(value) {
  return String(value || "").trim().split(/\s+/)[0].replace(/[^a-zA-Z'-]/g, "").toLowerCase();
}

/**
 * A coach or the owner naming a client. Full name is case-insensitive.
 * A first name or a shorter piece matches only when one client fits.
 * @returns {{id: string, name: string} | null}
 */
export function matchClientTag(body, clients) {
  const list = (clients || [])
    .filter((c) => c && c.role === "client")
    .map((c) => ({ id: c.id, name: personName(c), key: coachNameKey(personName(c)) }))
    .filter((c) => c.key);
  const source = String(body || "");
  for (let i = 0; i < source.length; i++) {
    if (source[i] !== "@") continue;
    const afterRaw = source.slice(i + 1);
    const afterKey = coachNameKey(afterRaw);
    if (!afterKey) continue;
    const full = list
      .filter((c) => afterKey.startsWith(c.key))
      .sort((a, b) => b.key.length - a.key.length || a.key.localeCompare(b.key));
    if (full.length === 1) return { id: full[0].id, name: full[0].name };
    if (full.length > 1 && full[0].key.length > full[1].key.length) {
      return { id: full[0].id, name: full[0].name };
    }
    if (full.length > 1) return null;
    const prefix = list.filter((c) => c.key.startsWith(afterKey));
    if (prefix.length === 1) return { id: prefix[0].id, name: prefix[0].name };
    if (prefix.length > 1) return null;
    const firstName = list.filter((c) => firstToken(c.name) === firstToken(afterRaw));
    if (firstName.length === 1) return { id: firstName[0].id, name: firstName[0].name };
  }
  return null;
}

/** iOS tapbacks we store as a like. Anything else returns null and is a normal text. */
export function parseTapback(body) {
  const text = String(body || "").trim();
  const loved = text.match(/^(Liked|Loved)\s+["“](.+)["”]$/i);
  if (loved) {
    return {
      reaction: loved[1].toLowerCase() === "loved" ? "heart" : "thumb",
      quote: loved[2],
    };
  }
  const reacted = text.match(/^Reacted\s+(.+?)\s+to\s+["“](.+)["”]$/i);
  if (!reacted) return null;
  const glyph = reacted[1].trim().toLowerCase();
  if (glyph.includes("👍") || glyph === "thumb" || glyph === "+1") {
    return { reaction: "thumb", quote: reacted[2] };
  }
  if (glyph.includes("❤") || glyph.includes("♥") || glyph === "heart") {
    return { reaction: "heart", quote: reacted[2] };
  }
  return null;
}

export function quoteMatches(storedBody, quote) {
  const q = String(quote || "").trim();
  if (!q) return false;
  const body = String(storedBody || "").trim();
  if (body === q) return true;
  const split = body.indexOf(": ");
  if (split !== -1 && body.slice(split + 2).trim() === q) return true;
  return body.endsWith(q);
}

/**
 * Several profiles can share a last-10. One match is used.
 * Several matches with exactly one client: that client (a coach must not
 * share a number with a client; if they do, the client wins and we say so).
 * Otherwise we do not guess.
 */
export function pickProfileForSms(matches) {
  const rows = matches || [];
  if (rows.length === 0) return null;
  if (rows.length === 1) return rows[0];
  const clients = rows.filter((row) => row.role === "client");
  if (clients.length === 1) return clients[0];
  return null;
}

function pairKey(a, b) {
  return [a, b].sort().join("|");
}

let _seq = 1;
function nextId(prefix) {
  _seq += 1;
  return `${prefix}-${_seq}`;
}

/** Coach and owner. Clients are not staff, and neither is any other role. */
export function isStaffRole(role) {
  return role === "coach" || role === "owner";
}

/**
 * Who a saved chat row should text.
 *
 * A client message keeps the staff route: the coach on the row, or null
 * when the row is Business Chat (the caller then uses the owner).
 * The owner or any coach texts the client, including an owner reply inside
 * a coach's thread, where trainer_id stays that coach and sender_id is the
 * owner. Consent and the invite hold are applied to that client afterwards.
 * Coach assignment is not read.
 */
export function smsRecipientId({ sender, clientId, trainerId } = {}) {
  const senderId = sender?.id ?? null;
  if (!senderId) return null;
  if (isStaffRole(sender?.role) && senderId !== clientId) return clientId ?? null;
  if (senderId === clientId) return trainerId ?? null;
  if (senderId !== trainerId) return trainerId ?? null;
  return clientId ?? null;
}

/**
 * Clients need sms_consent_at or clients.sms_opt_in.
 * A coach or the owner does not: a phone and not having opted out is enough.
 */
export function hasSmsConsent({ role, smsConsentAt, smsOptIn } = {}) {
  if (isStaffRole(role)) return true;
  return smsConsentAt != null || smsOptIn === true;
}

/**
 * Whether a person can be texted.
 * Staff: a phone number, and sms_opted_out is not true.
 * Clients: that, plus consent. No coach assignment is consulted.
 */
export function canText(person) {
  if (!person) return false;
  const phone = String(person.phone || "").trim();
  if (!phone || person.optedOut === true) return false;
  if (isStaffRole(person.role)) return true;
  return person.hasConsent === true;
}

/** A client writing to a coach or the owner. The channel picker does not apply. */
export function clientToStaff(sender, recipient) {
  return sender?.role === "client" && isStaffRole(recipient?.role);
}

/**
 * SMS body for a row that is already saved.
 * Client to staff uses the conversation relay ("Name: text"). A body that
 * already starts with that name is left alone. An inbound text that landed
 * in Business Chat keeps the existing notice.
 */
export function savedMessageText({ sender, recipient, body, originChannel, routedTo, groupName }) {
  if (originChannel === "sms" && routedTo === "business") {
    return businessNotice(sender?.displayName);
  }
  if (clientToStaff(sender, recipient)) {
    return prefixBody(sender?.displayName, body);
  }
  const named = sanitizeBroadcastName(groupName);
  if (named) return prefixBody(named, body);
  return body;
}

/** Title and body for the staff push. Same words client-notify already uses. */
export function staffPushCopy(clientName, messageBody) {
  const name = String(clientName || "").trim() || "a client";
  const text = String(messageBody || "").trim().slice(0, 500);
  return {
    title: `New message from ${name}`,
    body: text || "New message",
  };
}

/**
 * In-memory gym used by the tests and mirrored by the text handler.
 * People: {id, role, displayName, coachName, phone, optedOut, hasConsent}
 */
export class ThreadBook {
  constructor(people) {
    this.people = new Map(people.map((p) => [p.id, {
      optedOut: false,
      hasConsent: false,
      declined: false,
      inviteSentAt: null,
      inviteText: null,
      phone: "",
      coachName: "",
      ...p,
    }]));
    this.conversations = new Map();
    this.messages = [];
    this.likes = [];
    this.outbox = [];
    this.leads = [];
    // Matches app_config.sms_invite_enabled. Off until a test or the
    // server turns it on. No invite is queued while this is false.
    this.inviteEnabled = false;
  }

  person(id) {
    const found = this.people.get(id);
    if (!found) throw new Error(`unknown person ${id}`);
    return found;
  }

  coaches() {
    return [...this.people.values()].filter((p) => p.role === "coach");
  }

  clients() {
    return [...this.people.values()].filter((p) => p.role === "client");
  }

  /** The client this person messaged most recently inside the 6-hour window. */
  lastMessagedClient(personId, now) {
    for (const convo of this.activeConvos(personId, now)) {
      const otherId = convo.a === personId ? convo.b : convo.a;
      const other = this.people.get(otherId);
      if (other && other.role === "client") return other;
    }
    return null;
  }

  owner() {
    return [...this.people.values()].find((p) => p.role === "owner") || null;
  }

  canText(person) {
    return canText(person);
  }

  convoBetween(a, b) {
    return this.conversations.get(pairKey(a, b)) || null;
  }

  /** Existing threads and saved messages, so a new text can see the window. */
  seed({ conversations = [], messages = [] } = {}) {
    for (const convo of conversations) {
      this.conversations.set(convo.key, {
        key: convo.key,
        a: convo.a,
        b: convo.b,
        lastActivityAt: convo.lastActivityAt ?? null,
        routedTo: convo.routedTo,
      });
    }
    for (const message of messages) this.messages.push(message);
  }

  ensureConvo(a, b) {
    const key = pairKey(a.id, b.id);
    const existing = this.conversations.get(key);
    if (existing) return existing;
    const routedTo = a.role === "owner" || b.role === "owner" ? "business" : "conversation";
    const created = { key, a: a.id, b: b.id, lastActivityAt: null, routedTo };
    this.conversations.set(key, created);
    return created;
  }

  bump(convo, now) {
    convo.lastActivityAt = now;
  }

  activeConvos(personId, now) {
    return [...this.conversations.values()]
      .filter((c) => (c.a === personId || c.b === personId) && windowOpen(c.lastActivityAt, now))
      .sort((a, b) => b.lastActivityAt - a.lastActivityAt || a.key.localeCompare(b.key));
  }

  addMessage({ convo, sender, raw, at, channel, direction, routedTo, alreadyPrefixed = false }) {
    const body = alreadyPrefixed ? raw : prefixBody(sender.displayName, raw);
    const message = {
      id: nextId("msg"),
      conversationKey: convo.key,
      senderId: sender.id,
      body,
      raw,
      at,
      channel,
      direction,
      routedTo: routedTo || convo.routedTo,
    };
    this.messages.push(message);
    this.bump(convo, at);
    return message;
  }

  textPerson(person, body) {
    if (!this.canText(person)) return false;
    this.outbox.push({ toId: person.id, body, at: this.outbox.length });
    return true;
  }

  /**
   * App send. The message is in the shared thread.
   * A client writing a coach or the owner is always texted the prefixed
   * message. includeSms false is the in-app choice for everyone else,
   * including whether that client is texted back.
   */
  sendApp({ fromId, toId, text, now, includeSms = true }) {
    const from = this.person(fromId);
    const to = this.person(toId);
    const before = this.outbox.length;
    const convo = this.ensureConvo(from, to);
    const message = this.addMessage({
      convo,
      sender: from,
      raw: text,
      at: now,
      channel: "app",
      direction: "outbound",
    });
    this._relaySaved({ from, to, message, includeSms, now });

    if (from.role === "owner" && convo.routedTo === "business") {
      const tagged = matchCoachTag(text, this.coaches()) || matchCoachTag(message.body, this.coaches());
      if (tagged && tagged.id !== to.id && tagged.id !== from.id) {
        const coach = this.person(tagged.id);
        const coachThread = this.ensureConvo(to, coach);
        const copy = this.addMessage({
          convo: coachThread,
          sender: from,
          raw: message.body,
          at: now,
          channel: "app",
          direction: "outbound",
          routedTo: "conversation",
          alreadyPrefixed: true,
        });
        if (includeSms) this.textPerson(coach, copy.body);
      }
    }

    return { message, sms: this.outbox.slice(before) };
  }

  /**
   * Staff to a client follows the invite rules. Everyone else is texted
   * only when canText says so. A client writing staff still ignores the
   * channel picker.
   */
  _relaySaved({ from, to, message, includeSms, now }) {
    if (includeSms && isStaffRole(from.role) && to.role === "client") {
      const action = staffClientSmsAction(to, { inviteEnabled: this.inviteEnabled === true });
      if (action === "send") this.textPerson(to, message.body);
      else if (action === "invite") {
        this.outbox.push({ toId: to.id, body: INVITE_SMS_BODY, at: this.outbox.length, kind: "invite" });
        to.inviteSentAt = new Date(now).toISOString();
        to.inviteText = INVITE_SMS_BODY;
        message.smsPending = true;
      } else if (action === "hold" || action === "disabled") {
        message.smsPending = true;
      }
      return;
    }
    if (includeSms || clientToStaff(from, to)) this.textPerson(to, message.body);
  }

  likeApp({ userId, messageId, reaction, now }) {
    const message = this.messages.find((m) => m.id === messageId);
    if (!message) throw new Error("message missing");
    const convo = this.conversations.get(message.conversationKey);
    const beforeActivity = convo.lastActivityAt;
    const beforeOutbox = this.outbox.length;
    this.likes.push({
      messageId,
      userId,
      reaction,
      source: "app",
      at: now,
      channel: "app",
      direction: "outbound",
      routedTo: message.routedTo,
    });
    if (convo.lastActivityAt !== beforeActivity) throw new Error("a like moved the window");
    return { likes: this.likesFor(messageId), sms: this.outbox.slice(beforeOutbox), lastActivityAt: convo.lastActivityAt };
  }

  likesFor(messageId) {
    return this.likes.filter((like) => like.messageId === messageId);
  }

  newestMatch(conversationKey, quote) {
    const hits = this.messages.filter((m) => m.conversationKey === conversationKey && quoteMatches(m.body, quote));
    hits.sort((a, b) => b.at - a.at);
    return hits[0] || null;
  }

  /**
   * A text to the business number.
   * Returns { kind, message, like, sms, twiml, routedTo }.
   */
  receiveSms({ fromId, text, now, phone }) {
    const before = this.outbox.length;
    if (!fromId) {
      this.leads.push({
        phone: phone || "",
        body: text,
        at: now,
        channel: "sms",
        direction: "inbound",
        routedTo: "business",
      });
      const owner = this.owner();
      if (owner) this.textPerson(owner, businessNotice(unknownSenderLabel(phone)));
      return { kind: "lead", twiml: leadReply(), sms: this.outbox.slice(before), routedTo: "business" };
    }

    const keyword = keywordKind(text);
    if (keyword === "stop") {
      const person = this.person(fromId);
      person.optedOut = true;
      person.hasConsent = false;
      return { kind: "stop", twiml: null, sms: [], routedTo: null };
    }
    if (keyword === "help") {
      return { kind: "help", twiml: HELP_TEXT, sms: [], routedTo: null };
    }
    if (keyword === "start") {
      const person = this.person(fromId);
      person.optedOut = false;
      person.hasConsent = true;
      return { kind: "start", twiml: null, sms: [], routedTo: null };
    }

    const from = this.person(fromId);
    // YES accepts the invite. It is not a chat message. A client who already
    // agreed, or who never got an invite, is saying yes to a person.
    if (
      from.role === "client" &&
      isInviteYes(text) &&
      from.inviteSentAt &&
      from.optedOut !== true &&
      from.declined !== true &&
      from.hasConsent !== true
    ) {
      from.hasConsent = true;
      from.declined = false;
      return {
        kind: "invite-yes",
        twiml: null,
        confirmation: INVITE_YES_CONFIRMATION,
        consentText: inviteConsentRecord(from.inviteText || INVITE_SMS_BODY),
        sms: [],
        deliverHeld: true,
        routedTo: null,
      };
    }

    const tap = parseTapback(text);
    if (tap) {
      const active = this.activeConvos(from.id, now);
      const convo = active[0];
      const hit = convo ? this.newestMatch(convo.key, tap.quote) : null;
      if (hit) {
        const activity = convo.lastActivityAt;
        this.likes.push({
          messageId: hit.id,
          userId: from.id,
          reaction: tap.reaction,
          source: "sms_tapback",
          at: now,
          channel: "sms",
          direction: "inbound",
          routedTo: hit.routedTo,
        });
        return {
          kind: "like",
          like: this.likes.at(-1),
          message: hit,
          sms: [],
          windowReset: convo.lastActivityAt !== activity,
          lastActivityAt: convo.lastActivityAt,
          routedTo: hit.routedTo,
        };
      }
    }

    if (from.role === "coach") {
      const clientTag = matchClientTag(text, this.clients());
      if (clientTag && clientTag.id !== from.id) {
        return this._deliverInbound(from, this.person(clientTag.id), text, now, "tag", before);
      }
      const recentClient = this.lastMessagedClient(from.id, now);
      if (recentClient) {
        return this._deliverInbound(from, recentClient, text, now, "active", before);
      }
    } else {
      const tagged = matchCoachTag(text, this.coaches());
      if (tagged && tagged.id !== from.id) {
        const coach = this.person(tagged.id);
        return this._deliverInbound(from, coach, text, now, "tag", before);
      }
      if (from.role === "owner") {
        const clientTag = matchClientTag(text, this.clients());
        if (clientTag) {
          return this._deliverInbound(from, this.person(clientTag.id), text, now, "tag", before);
        }
      }
    }

    const active = this.activeConvos(from.id, now);
    if (active.length > 0) {
      const convo = active[0];
      const otherId = convo.a === from.id ? convo.b : convo.a;
      return this._deliverInbound(from, this.person(otherId), text, now, "active", before);
    }

    const owner = this.owner();
    if (!owner || owner.id === from.id) {
      this.leads.push({
        phone: from.phone || phone || "",
        body: text,
        at: now,
        channel: "sms",
        direction: "inbound",
        routedTo: "business",
        senderId: from.id,
      });
      return { kind: "business", message: null, sms: [], twiml: null, routedTo: "business" };
    }
    return this._deliverInbound(from, owner, text, now, "fallthrough", before);
  }

  _deliverInbound(from, to, text, now, how, before) {
    const convo = this.ensureConvo(from, to);
    const message = this.addMessage({
      convo,
      sender: from,
      raw: text,
      at: now,
      channel: "sms",
      direction: "inbound",
    });
    if (how === "fallthrough") {
      this.textPerson(to, businessNotice(from.displayName));
    } else {
      this.textPerson(to, message.body);
    }
    return {
      kind: how,
      message,
      sms: this.outbox.slice(before),
      twiml: null,
      routedTo: message.routedTo,
      conversationKey: convo.key,
    };
  }
}

/**
 * Staff messages held for SMS, oldest first, in the same wording a live
 * send would have used. who must be "trainer". The sender name is the
 * coach name already on the row.
 */
export function heldStaffTexts(rows) {
  return (rows || [])
    .filter((row) => row && row.smsPending === true && row.who === "trainer")
    .slice()
    .sort((a, b) => (a.at || 0) - (b.at || 0) || String(a.id).localeCompare(String(b.id)))
    .map((row) => ({
      id: row.id,
      body: savedMessageText({
        sender: row.sender,
        recipient: row.recipient,
        body: row.body,
        originChannel: row.originChannel || "app",
        routedTo: row.routedTo || "conversation",
        groupName: row.groupName,
      }),
    }));
}

/** What the app-send texter should send for a row that is already saved. */
export function planTextsForSavedMessage({ sender, recipient, body, originChannel, routedTo, coaches, includeSms = true, groupName, inviteEnabled = false }) {
  const sms = [];
  const passAlong = [];
  let clientSms = null;
  let invite = null;
  let hold = false;
  const staffToClient = Boolean(includeSms && isStaffRole(sender?.role) && recipient?.role === "client");
  if (staffToClient) {
    // Never reads primary_trainer_id. The action only looks at consent,
    // opt-out, an in-app decline, a phone, whether the invite went out,
    // and the server flag that defaults to off.
    clientSms = staffClientSmsAction(recipient, { inviteEnabled });
    if (clientSms === "send") {
      sms.push({
        toId: recipient.id,
        body: savedMessageText({ sender, recipient, body, originChannel, routedTo, groupName }),
      });
    } else if (clientSms === "invite") {
      invite = { toId: recipient.id, body: INVITE_SMS_BODY };
      hold = true;
    } else if (clientSms === "hold" || clientSms === "disabled") {
      hold = true;
    }
  } else if ((includeSms || clientToStaff(sender, recipient)) && recipient && canText(recipient)) {
    // Client to staff ignores the channel picker. Staff to client still honors it.
    sms.push({
      toId: recipient.id,
      body: savedMessageText({ sender, recipient, body, originChannel, routedTo, groupName }),
    });
  }
  if (sender.role === "owner" && routedTo === "business" && recipient) {
    const tagged = matchCoachTag(body, coaches);
    if (tagged && tagged.id !== recipient.id && tagged.id !== sender.id) {
      passAlong.push({ coachId: tagged.id, clientId: recipient.id, body });
    }
  }
  return { sms, passAlong, clientSms, invite, hold };
}
