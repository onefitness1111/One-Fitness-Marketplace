import assert from "node:assert/strict";
import test from "node:test";
import {
  BUSINESS_NAME,
  HELP_TEXT,
  ThreadBook,
  businessNotice,
  keywordKind,
  leadReply,
  matchCoachTag,
  matchClientTag,
  parseTapback,
  pickProfileForSms,
  canText,
  clientToStaff,
  hasSmsConsent,
  planTextsForSavedMessage,
  prefixBody,
  smsRecipientId,
  staffPushCopy,
  INVITE_SMS_BODY,
  INVITE_YES_CONFIRMATION,
  heldStaffTexts,
  quoteMatches,
  windowOpen,
  WINDOW_MS,
} from "./chatRouting.mjs";

const T0 = Date.parse("2026-06-01T15:00:00Z");
const MIN = 60 * 1000;

function gym() {
  return new ThreadBook([
    { id: "chris", role: "coach", displayName: "Coach Chris", coachName: "Coach Chris", phone: "+15551110001", hasConsent: true },
    { id: "pat", role: "coach", displayName: "Coach Pat", coachName: "Coach Pat", phone: "+15551110003", hasConsent: true },
    { id: "sam", role: "client", displayName: "Sam", phone: "+15551110002", hasConsent: true },
    { id: "bob", role: "client", displayName: "Bob", phone: "+15551110004", hasConsent: true },
    { id: "owner", role: "owner", displayName: BUSINESS_NAME, phone: "+15551235455", hasConsent: true },
  ]);
}

test("1. a coach sends, and the client gets the app thread plus a text", () => {
  const book = gym();
  const sent = book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  assert.equal(sent.message.body, "Coach Chris: See you at 6");
  assert.equal(sent.message.channel, "app");
  assert.equal(sent.message.direction, "outbound");
  assert.equal(sent.message.routedTo, "conversation");
  assert.equal(sent.sms.length, 1);
  assert.equal(sent.sms[0].toId, "sam");
  assert.equal(sent.sms[0].body, "Coach Chris: See you at 6");
  assert.equal(book.messages.length, 1);
});

test("2. a client's text at 5h59m still goes to the coach", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  const reply = book.receiveSms({ fromId: "sam", text: "On my way", now: T0 + 5 * 60 * MIN + 59 * MIN });
  assert.equal(reply.kind, "active");
  assert.equal(reply.message.senderId, "sam");
  assert.equal(reply.message.body, "Sam: On my way");
  assert.equal(reply.routedTo, "conversation");
  assert.equal(reply.sms.length, 1);
  assert.equal(reply.sms[0].toId, "chris");
  assert.equal(reply.sms[0].body, "Sam: On my way");
});

test("3. an untagged text at 6h01m goes to Business Chat and texts the owner", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  const reply = book.receiveSms({ fromId: "sam", text: "Still outside?", now: T0 + WINDOW_MS + MIN });
  assert.equal(reply.kind, "fallthrough");
  assert.equal(reply.routedTo, "business");
  assert.equal(reply.message.senderId, "sam");
  assert.equal(reply.sms.length, 1);
  assert.equal(reply.sms[0].toId, "owner");
  assert.equal(reply.sms[0].body, "New message from Sam in ONE Fitness Marketplace.");
});

test("4. @CoachChris reaches Coach Chris even when nothing is active", () => {
  const book = gym();
  for (const text of ["@CoachChris running late", "@Coach Chris running late", "@coachchris running late"]) {
    const sent = book.receiveSms({ fromId: "sam", text, now: T0 + 30 * 60 * MIN });
    assert.equal(sent.kind, "tag", text);
    assert.equal(sent.sms[0].toId, "chris", text);
    assert.equal(sent.message.body, `Sam: ${text}`);
    assert.equal(sent.routedTo, "conversation");
  }
});

test("5. back-and-forth resets the 6 hours from the latest message", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  const first = book.receiveSms({ fromId: "sam", text: "Ok", now: T0 + 5 * 60 * MIN });
  assert.equal(first.kind, "active");
  // 5h59m after that reply is almost 11 hours after the original text.
  // It only stays with the coach because the reply restarted the window.
  const second = book.receiveSms({
    fromId: "chris",
    text: "Gate's open",
    now: T0 + 5 * 60 * MIN + WINDOW_MS - MIN,
  });
  assert.equal(second.kind, "active");
  assert.equal(second.sms[0].toId, "sam");
  const expired = book.receiveSms({
    fromId: "sam",
    text: "Hello?",
    now: T0 + 5 * 60 * MIN + WINDOW_MS - MIN + WINDOW_MS + MIN,
  });
  assert.equal(expired.kind, "fallthrough");
});

test("6. Liked \"See you at 6\" is a like, with no text and no window reset", () => {
  const book = gym();
  const sent = book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  const liked = book.receiveSms({ fromId: "sam", text: 'Liked "See you at 6"', now: T0 + 60 * MIN });
  assert.equal(liked.kind, "like");
  assert.equal(liked.like.reaction, "thumb");
  assert.equal(liked.like.source, "sms_tapback");
  assert.equal(liked.like.channel, "sms");
  assert.equal(liked.sms.length, 0);
  assert.equal(liked.windowReset, false);
  assert.equal(book.convoBetween("chris", "sam").lastActivityAt, T0);
  const later = book.receiveSms({ fromId: "sam", text: "You there?", now: T0 + WINDOW_MS + MIN });
  assert.equal(later.kind, "fallthrough");
  assert.equal(sent.message.id, liked.message.id);
});

test("7. an in-app like is seen by both, and sends no text", () => {
  const book = gym();
  const sent = book.sendApp({ fromId: "chris", toId: "sam", text: "Nice work", now: T0 });
  const heart = book.likeApp({ userId: "sam", messageId: sent.message.id, reaction: "heart", now: T0 + MIN });
  const thumb = book.likeApp({ userId: "chris", messageId: sent.message.id, reaction: "thumb", now: T0 + 2 * MIN });
  assert.equal(heart.sms.length, 0);
  assert.equal(thumb.sms.length, 0);
  assert.deepEqual(
    book.likesFor(sent.message.id).map((like) => `${like.userId}:${like.reaction}`),
    ["sam:heart", "chris:thumb"],
  );
  assert.equal(book.convoBetween("chris", "sam").lastActivityAt, T0);
});

test("8. @Bob is treated as untagged, even when a client is named Bob", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  const during = book.receiveSms({ fromId: "sam", text: "@Bob running late", now: T0 + 30 * MIN });
  assert.equal(during.kind, "active");
  assert.equal(during.sms[0].toId, "chris");
  const cold = new ThreadBook([...gym().people.values()]);
  const missed = cold.receiveSms({ fromId: "sam", text: "@Bob running late", now: T0 });
  assert.equal(missed.kind, "fallthrough");
  assert.equal(missed.routedTo, "business");
  assert.equal(matchCoachTag("@Bob", cold.coaches()), null);
  assert.equal(matchCoachTag("@Bob", [{ id: "bob", role: "client", displayName: "Bob", coachName: "Bob" }]), null);
});

test("9. with two active conversations, an untagged reply goes to the newest", () => {
  const book = gym();
  book.sendApp({ fromId: "sam", toId: "chris", text: "Question for Chris", now: T0 });
  book.sendApp({ fromId: "sam", toId: "pat", text: "Question for Pat", now: T0 + 60 * MIN });
  const reply = book.receiveSms({ fromId: "sam", text: "Following up", now: T0 + 90 * MIN });
  assert.equal(reply.kind, "active");
  assert.equal(reply.sms[0].toId, "pat");
  assert.equal(reply.message.body, "Sam: Following up");
});

test("10. after STOP there is no text, but the app thread still works", () => {
  const book = gym();
  const stopped = book.receiveSms({ fromId: "sam", text: "STOP", now: T0 });
  assert.equal(stopped.kind, "stop");
  assert.equal(book.person("sam").optedOut, true);
  const fromCoach = book.sendApp({ fromId: "chris", toId: "sam", text: "Checking in", now: T0 + MIN });
  assert.equal(fromCoach.message.body, "Coach Chris: Checking in");
  assert.equal(fromCoach.sms.length, 0);
  assert.equal(book.messages.length, 1);
  const fromSam = book.sendApp({ fromId: "sam", toId: "chris", text: "I'm in the app", now: T0 + 2 * MIN });
  assert.equal(fromSam.message.channel, "app");
  assert.equal(fromSam.sms.length, 1);
  assert.equal(fromSam.sms[0].toId, "chris");
});

test("11. a coach's untagged text goes to their newest active conversation", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "bob", text: "Bring shoes", now: T0 });
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 + 30 * MIN });
  const text = book.receiveSms({ fromId: "chris", text: "Running five late", now: T0 + 50 * MIN });
  assert.equal(text.kind, "active");
  assert.equal(text.message.senderId, "chris");
  assert.equal(text.message.body, "Coach Chris: Running five late");
  assert.equal(text.sms[0].toId, "sam");
  assert.equal(text.routedTo, "conversation");
});

test("the window is closed at exactly 6 hours", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  assert.equal(windowOpen(T0, T0 + WINDOW_MS - 1), true);
  assert.equal(windowOpen(T0, T0 + WINDOW_MS), false);
  const reply = book.receiveSms({ fromId: "sam", text: "Now", now: T0 + WINDOW_MS });
  assert.equal(reply.kind, "fallthrough");
});

test("Loved and a thumbs-up tapback are likes, and a miss is a normal text", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  const loved = book.receiveSms({ fromId: "sam", text: 'Loved "See you at 6"', now: T0 + MIN });
  assert.equal(loved.kind, "like");
  assert.equal(loved.like.reaction, "heart");
  const thumb = book.receiveSms({ fromId: "sam", text: 'Reacted 👍 to "See you at 6"', now: T0 + 2 * MIN });
  assert.equal(thumb.kind, "like");
  assert.equal(thumb.like.reaction, "thumb");
  const missed = book.receiveSms({ fromId: "sam", text: 'Liked "a different sentence"', now: T0 + 3 * MIN });
  assert.equal(missed.kind, "active");
  assert.equal(missed.message.body, 'Sam: Liked "a different sentence"');
});

test("UNSUBSCRIBE and HELP are handled, and a plain Yes is a real reply", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "Can you make it?", now: T0 });
  const yes = book.receiveSms({ fromId: "sam", text: "YES", now: T0 + MIN });
  assert.equal(yes.kind, "active");
  assert.equal(yes.message.body, "Sam: YES");
  const help = book.receiveSms({ fromId: "sam", text: "help", now: T0 + 2 * MIN });
  assert.equal(help.kind, "help");
  assert.equal(help.twiml, HELP_TEXT);
  assert.equal(help.twiml.toLowerCase().includes("password"), false);
  const off = book.receiveSms({ fromId: "sam", text: "unsubscribe", now: T0 + 3 * MIN });
  assert.equal(off.kind, "stop");
  assert.equal(keywordKind("STOPALL"), "stop");
  assert.equal(keywordKind("START"), "start");
});

test("an unknown number gets the signup text and the owner gets a notice", () => {
  const book = gym();
  const lead = book.receiveSms({ fromId: null, phone: "+15559990000", text: "Do you have openings?", now: T0 });
  assert.equal(lead.kind, "lead");
  assert.match(lead.twiml, /not a ONE Fitness client yet/);
  assert.match(lead.twiml, /APP_STORE_LINK/);
  assert.match(lead.twiml, /GOOGLE_PLAY_LINK/);
  assert.equal(lead.sms[0].body, businessNotice("a new number ending 0000"));
  assert.equal(book.leads.length, 1);
  assert.equal(book.messages.length, 0);
});

test("the owner can tag a coach in Business Chat to pass the message along", () => {
  const book = gym();
  const sent = book.sendApp({
    fromId: "owner",
    toId: "sam",
    text: "@CoachChris can you take this one?",
    now: T0,
  });
  assert.equal(sent.message.routedTo, "business");
  assert.equal(sent.sms.some((row) => row.toId === "sam"), true);
  assert.equal(sent.sms.some((row) => row.toId === "chris"), true);
  const coachThread = book.messages.filter((m) => m.conversationKey === book.convoBetween("sam", "chris").key);
  assert.equal(coachThread.length, 1);
  assert.match(coachThread[0].body, /ONE Fitness Marketplace: @CoachChris/);
});

test("names ignore case and spaces, and a longer coach name wins", () => {
  const coaches = [
    { id: "chris", role: "coach", coachName: "Coach Chris" },
    { id: "tina", role: "coach", coachName: "Coach Christina" },
  ];
  assert.equal(matchCoachTag("@CoachChristina hi", coaches).id, "tina");
  assert.equal(matchCoachTag("@coach chris hi", coaches).id, "chris");
  assert.equal(prefixBody("Coach Chris", "Coach Chris: already"), "Coach Chris: already");
  assert.equal(quoteMatches("Coach Chris: See you at 6", "See you at 6"), true);
});

test("two profiles on one number are not guessed, unless exactly one is a client", () => {
  assert.equal(pickProfileForSms([]), null);
  assert.equal(pickProfileForSms([{ id: "c", role: "coach" }]).id, "c");
  assert.equal(
    pickProfileForSms([{ id: "c", role: "coach" }, { id: "s", role: "client" }]).id,
    "s",
  );
  assert.equal(pickProfileForSms([{ id: "a", role: "coach" }, { id: "b", role: "coach" }]), null);
});

test("a saved thread is what a later text and a tapback attach to", () => {
  const book = gym();
  const key = ["chris", "sam"].sort().join("|");
  book.seed({
    conversations: [{ key, a: "chris", b: "sam", lastActivityAt: T0, routedTo: "conversation" }],
    messages: [{
      id: "existing",
      conversationKey: key,
      senderId: "chris",
      body: "Coach Chris: See you at 6",
      at: T0,
      channel: "app",
      direction: "outbound",
      routedTo: "conversation",
    }],
  });
  const reply = book.receiveSms({ fromId: "sam", text: "On my way", now: T0 + 10 * MIN });
  assert.equal(reply.kind, "active");
  const like = book.receiveSms({ fromId: "sam", text: 'Liked "See you at 6"', now: T0 + 11 * MIN });
  assert.equal(like.kind, "like");
  assert.equal(like.like.messageId, "existing");
  assert.equal(book.convoBetween("chris", "sam").lastActivityAt, T0 + 10 * MIN);
});

test("a coach's @Client Name reaches that client, and the text is prefixed with the coach name", () => {
  const book = gym();
  book.people.set("alex", {
    id: "alex",
    role: "client",
    displayName: "Alex Johnson",
    phone: "+15551110009",
    hasConsent: true,
    optedOut: false,
    coachName: "",
  });
  book.people.set("alex2", {
    id: "alex2",
    role: "client",
    displayName: "Alex Smith",
    phone: "+15551110008",
    hasConsent: true,
    optedOut: false,
    coachName: "",
  });
  const tagged = book.receiveSms({ fromId: "chris", text: "@Alex Johnson on my way", now: T0 });
  assert.equal(tagged.kind, "tag");
  assert.equal(tagged.sms[0].toId, "alex");
  assert.equal(tagged.message.body, "Coach Chris: @Alex Johnson on my way");
  assert.equal(tagged.message.body.includes("Christopher"), false);
  const lower = book.receiveSms({ fromId: "chris", text: "@alex johnson thanks", now: T0 + MIN });
  assert.equal(lower.sms[0].toId, "alex");
  const cold = new ThreadBook([...book.people.values()].map((p) => ({ ...p })));
  const ambiguous = cold.receiveSms({ fromId: "chris", text: "@Alex which room?", now: T0 });
  assert.equal(ambiguous.kind, "fallthrough");
  assert.equal(ambiguous.routedTo, "business");
  const onlySam = new ThreadBook([
    { id: "chris", role: "coach", displayName: "Coach Chris", coachName: "Coach Chris", phone: "+15551110001", hasConsent: true },
    { id: "sam", role: "client", displayName: "Sam Rivera", phone: "+15551110002", hasConsent: true },
    { id: "owner", role: "owner", displayName: BUSINESS_NAME, phone: "+15551235455", hasConsent: true },
  ]);
  const first = onlySam.receiveSms({ fromId: "chris", text: "@Sam ready", now: T0 });
  assert.equal(first.sms[0].toId, "sam");
});

test("a coach with no tag texts the client they last messaged inside 6 hours, otherwise the business", () => {
  const book = gym();
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you at 6", now: T0 });
  book.sendApp({ fromId: "chris", toId: "owner", text: "Question for the desk", now: T0 + 40 * MIN });
  const follow = book.receiveSms({ fromId: "chris", text: "Still on for 6", now: T0 + 50 * MIN });
  assert.equal(follow.kind, "active");
  assert.equal(follow.sms[0].toId, "sam");
  const later = book.receiveSms({
    fromId: "chris",
    text: "Hello?",
    now: T0 + 50 * MIN + WINDOW_MS,
  });
  assert.equal(later.kind, "fallthrough");
  assert.equal(later.routedTo, "business");
});

test("the owner can tag a client by name", () => {
  const book = gym();
  const sent = book.receiveSms({ fromId: "owner", text: "@Sam the desk got your note", now: T0 });
  assert.equal(sent.kind, "tag");
  assert.equal(sent.sms[0].toId, "sam");
  assert.equal(sent.message.body.startsWith(`${BUSINESS_NAME}:`), true);
});

test("a lead reply does not ask for a password", () => {
  assert.equal(leadReply().toLowerCase().includes("password"), false);
  assert.equal(parseTapback('Disliked "See you at 6"'), null);
});

test("a broadcast text uses the group name, and a one-on-one text keeps its stored prefix", () => {
  const person = { id: "sam", phone: "+15551110002", hasConsent: true, optedOut: false };
  const sender = { id: "chris", role: "coach", displayName: "Coach Chris" };
  const broadcast = planTextsForSavedMessage({
    sender,
    recipient: person,
    body: "See you at 6",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    groupName: "Morning\ncrew",
  });
  assert.equal(broadcast.sms[0].body, "Morning crew: See you at 6");

  const direct = planTextsForSavedMessage({
    sender,
    recipient: person,
    body: "Coach Chris: See you at 6",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
  });
  assert.equal(direct.sms[0].body, "Coach Chris: See you at 6");
});

test("a client's in-app message still texts a coach who never consented", () => {
  const book = gym();
  book.person("chris").hasConsent = false;
  const sent = book.sendApp({
    fromId: "sam",
    toId: "chris",
    text: "In the lobby",
    now: T0,
    includeSms: false,
  });
  assert.equal(sent.sms.length, 1);
  assert.equal(sent.sms[0].toId, "chris");
  assert.equal(sent.sms[0].body, "Sam: In the lobby");
  const reply = book.sendApp({
    fromId: "chris",
    toId: "sam",
    text: "On my way",
    now: T0 + MIN,
    includeSms: false,
  });
  assert.equal(reply.message.body, "Coach Chris: On my way");
  assert.equal(reply.sms.length, 0);
});

test("an inbound text reaches a coach or the owner without a consent timestamp", () => {
  const book = gym();
  book.person("chris").hasConsent = false;
  book.person("owner").hasConsent = false;
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you", now: T0, includeSms: false });
  const reply = book.receiveSms({ fromId: "sam", text: "Here", now: T0 + MIN });
  assert.equal(reply.sms.length, 1);
  assert.equal(reply.sms[0].toId, "chris");
  assert.equal(reply.sms[0].body, "Sam: Here");
  book.person("chris").optedOut = true;
  const blocked = book.receiveSms({ fromId: "sam", text: "Still here", now: T0 + 2 * MIN });
  assert.equal(blocked.sms.length, 0);
  const cold = new ThreadBook([
    { id: "sam", role: "client", displayName: "Sam", phone: "+15551110002", hasConsent: true },
    { id: "owner", role: "owner", displayName: BUSINESS_NAME, phone: "+15551235455", hasConsent: false },
  ]);
  const toOwner = cold.receiveSms({ fromId: "sam", text: "Hello?", now: T0 });
  assert.equal(toOwner.kind, "fallthrough");
  assert.equal(toOwner.sms[0].toId, "owner");
});

test("a client who never answered gets one invite, not the coach's message", () => {
  const book = gym();
  book.inviteEnabled = true;
  book.person("sam").hasConsent = false;
  book.person("sam").primaryTrainerId = null;
  const sent = book.sendApp({ fromId: "chris", toId: "sam", text: "See you", now: T0 });
  assert.equal(sent.message.body, "Coach Chris: See you");
  assert.equal(sent.message.smsPending, true);
  assert.equal(sent.sms.length, 1);
  assert.equal(sent.sms[0].body, INVITE_SMS_BODY);
  assert.equal(sent.sms[0].body.includes("Sam"), false);
  const again = book.sendApp({ fromId: "chris", toId: "sam", text: "Still here", now: T0 + MIN });
  assert.equal(again.sms.length, 0);
  assert.equal(again.message.smsPending, true);
  assert.equal(again.message.body, "Coach Chris: Still here");
  book.person("chris").phone = "";
  book.person("sam").hasConsent = true;
  const back = book.sendApp({ fromId: "sam", toId: "chris", text: "Ok", now: T0 + 2 * MIN, includeSms: false });
  assert.equal(back.sms.length, 0);
});

test("YES after the invite opts the client in and is not a chat message", () => {
  const book = gym();
  book.inviteEnabled = true;
  book.person("sam").hasConsent = false;
  book.sendApp({ fromId: "chris", toId: "sam", text: "See you", now: T0 });
  const before = book.messages.length;
  for (const text of ["YES", "y", "yes!", "ok yes"]) {
    book.person("sam").hasConsent = false;
    const yes = book.receiveSms({ fromId: "sam", text, now: T0 + MIN });
    assert.equal(yes.kind, "invite-yes", text);
    assert.equal(yes.confirmation, INVITE_YES_CONFIRMATION);
    assert.equal(yes.sms.length, 0);
    assert.equal(book.messages.length, before, text);
    assert.equal(book.person("sam").hasConsent, true);
  }
  const chatting = book.receiveSms({ fromId: "sam", text: "YES", now: T0 + 2 * MIN });
  assert.equal(chatting.kind, "active");
  assert.equal(chatting.message.body, "Sam: YES");
  const follow = book.sendApp({ fromId: "chris", toId: "sam", text: "Now by text", now: T0 + 3 * MIN });
  assert.equal(follow.sms.length, 1);
  assert.equal(follow.sms[0].body, "Coach Chris: Now by text");
  assert.equal(follow.message.smsPending, undefined);
});

test("held staff texts go out oldest first, in the coach's public name", () => {
  const texts = heldStaffTexts([
    {
      id: "b",
      who: "trainer",
      smsPending: true,
      at: 2,
      body: "Coach Pat: Later",
      sender: { role: "coach", displayName: "Coach Pat" },
      recipient: { role: "client" },
      originChannel: "app",
      routedTo: "conversation",
    },
    {
      id: "a",
      who: "trainer",
      smsPending: true,
      at: 1,
      body: "Coach Chris: See you",
      sender: { role: "coach", displayName: "Coach Chris" },
      recipient: { role: "client" },
      originChannel: "app",
      routedTo: "conversation",
    },
    {
      id: "c",
      who: "client",
      smsPending: true,
      at: 0,
      body: "Sam: no",
      sender: { role: "client", displayName: "Sam" },
      recipient: { role: "coach" },
    },
  ]);
  assert.deepEqual(texts.map((item) => item.body), ["Coach Chris: See you", "Coach Pat: Later"]);
});

test("STOP and an in-app decline get no invite", () => {
  const book = gym();
  book.inviteEnabled = true;
  book.person("sam").hasConsent = false;
  book.person("sam").declined = true;
  const declined = book.sendApp({ fromId: "owner", toId: "sam", text: "Hello", now: T0 });
  assert.equal(declined.sms.length, 0);
  assert.equal(declined.message.smsPending, undefined);
  book.person("sam").declined = false;
  book.person("sam").optedOut = true;
  const stopped = book.sendApp({ fromId: "chris", toId: "sam", text: "Hello again", now: T0 + MIN });
  assert.equal(stopped.sms.length, 0);
});

test("a saved in-app client message texts staff with the coach-facing name", () => {
  const coach = planTextsForSavedMessage({
    sender: { id: "sam", role: "client", displayName: "Sam Rivera" },
    recipient: { id: "chris", role: "coach", phone: "+15551110001", optedOut: false, hasConsent: false },
    body: "In the lobby",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: false,
  });
  assert.equal(coach.sms.length, 1);
  assert.equal(coach.sms[0].toId, "chris");
  assert.equal(coach.sms[0].body, "Sam Rivera: In the lobby");

  const already = planTextsForSavedMessage({
    sender: { id: "sam", role: "client", displayName: "Sam Rivera" },
    recipient: { id: "owner", role: "owner", phone: "+15551235455", optedOut: false, hasConsent: false },
    body: "Sam Rivera: In the lobby",
    originChannel: "app",
    routedTo: "business",
    coaches: [],
    includeSms: false,
  });
  assert.equal(already.sms[0].body, "Sam Rivera: In the lobby");

  const notice = planTextsForSavedMessage({
    sender: { id: "sam", role: "client", displayName: "Sam" },
    recipient: { id: "owner", role: "owner", phone: "+15551235455", optedOut: false, hasConsent: false },
    body: "Sam: Hello",
    originChannel: "sms",
    routedTo: "business",
    coaches: [],
    includeSms: true,
  });
  assert.equal(notice.sms[0].body, "New message from Sam in ONE Fitness Marketplace.");
});

test("staff to client still follows the channel picker and client consent", () => {
  const quiet = planTextsForSavedMessage({
    sender: { id: "chris", role: "coach", displayName: "Coach Chris" },
    recipient: { id: "sam", role: "client", phone: "+15551110002", optedOut: false, hasConsent: true },
    body: "Coach Chris: On my way",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: false,
  });
  assert.equal(quiet.sms.length, 0);
  assert.equal(quiet.clientSms, null);
  assert.equal(quiet.invite, null);
  const unconsented = planTextsForSavedMessage({
    sender: { id: "chris", role: "coach", displayName: "Coach Chris" },
    recipient: { id: "sam", role: "client", phone: "+15551110002", optedOut: false, hasConsent: false },
    body: "Coach Chris: On my way",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: true,
    inviteEnabled: true,
  });
  const invitesOff = planTextsForSavedMessage({
    sender: { id: "chris", role: "coach", displayName: "Coach Chris" },
    recipient: { id: "sam", role: "client", phone: "+15551110002", optedOut: false, hasConsent: false },
    body: "Coach Chris: On my way",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: true,
  });
  assert.equal(invitesOff.clientSms, "disabled");
  assert.equal(invitesOff.sms.length, 0);
  assert.equal(invitesOff.invite, null);
  assert.equal(invitesOff.hold, true);
  assert.equal(unconsented.sms.length, 0);
  assert.equal(unconsented.clientSms, "invite");
  assert.equal(unconsented.invite.body, INVITE_SMS_BODY);
  assert.equal(unconsented.hold, true);
  const held = planTextsForSavedMessage({
    sender: { id: "chris", role: "coach", displayName: "Coach Chris" },
    recipient: {
      id: "sam",
      role: "client",
      phone: "+15551110002",
      optedOut: false,
      hasConsent: false,
      inviteSentAt: "2026-11-21T00:00:00Z",
      primaryTrainerId: "someone-else",
    },
    body: "Coach Chris: On my way",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: true,
  });
  assert.equal(held.clientSms, "hold");
  assert.equal(held.invite, null);
  assert.equal(held.hold, true);
  assert.equal(held.sms.length, 0);
  const saidNo = planTextsForSavedMessage({
    sender: { id: "chris", role: "coach", displayName: "Coach Chris" },
    recipient: { id: "sam", role: "client", phone: "+15551110002", optedOut: false, declined: true, hasConsent: true },
    body: "Coach Chris: On my way",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: true,
  });
  assert.equal(saidNo.clientSms, "skip");
  assert.equal(saidNo.invite, null);
  assert.equal(saidNo.hold, false);
  const optedOut = planTextsForSavedMessage({
    sender: { id: "sam", role: "client", displayName: "Sam" },
    recipient: { id: "chris", role: "coach", phone: "+15551110001", optedOut: true, hasConsent: false },
    body: "Sam: Hi",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: false,
  });
  assert.equal(optedOut.sms.length, 0);
});

test("staff consent does not depend on a timestamp, and the push copy names the client", () => {
  assert.equal(hasSmsConsent({ role: "coach", smsConsentAt: null, smsOptIn: false }), true);
  assert.equal(hasSmsConsent({ role: "owner" }), true);
  assert.equal(hasSmsConsent({ role: "client", smsConsentAt: null, smsOptIn: false }), false);
  assert.equal(hasSmsConsent({ role: "client", smsConsentAt: "2026-11-19", smsOptIn: false }), true);
  assert.equal(hasSmsConsent({ role: "client", smsOptIn: true }), true);
  assert.equal(canText({ role: "coach", phone: "555", optedOut: false, hasConsent: false }), true);
  assert.equal(canText({ role: "coach", phone: "", hasConsent: false }), false);
  assert.equal(canText({ role: "owner", phone: "555", optedOut: true }), false);
  assert.equal(canText({ role: "client", phone: "555", hasConsent: false }), false);
  assert.equal(clientToStaff({ role: "client" }, { role: "coach" }), true);
  assert.equal(clientToStaff({ role: "client" }, { role: "owner" }), true);
  assert.equal(clientToStaff({ role: "coach" }, { role: "client" }), false);
  const push = staffPushCopy("Sam Rivera", "Sam Rivera: In the lobby");
  assert.equal(push.title, "New message from Sam Rivera");
  assert.equal(push.body, "Sam Rivera: In the lobby");
});

test("an owner reply in a coach thread texts the client, not the coach", () => {
  assert.equal(
    smsRecipientId({ sender: { id: "owner", role: "owner" }, clientId: "sam", trainerId: "chris" }),
    "sam",
  );
  assert.equal(
    smsRecipientId({ sender: { id: "pat", role: "coach" }, clientId: "sam", trainerId: "chris" }),
    "sam",
  );
  assert.equal(
    smsRecipientId({ sender: { id: "chris", role: "coach" }, clientId: "sam", trainerId: "chris" }),
    "sam",
  );
  assert.equal(
    smsRecipientId({ sender: { id: "sam", role: "client" }, clientId: "sam", trainerId: "chris" }),
    "chris",
  );
  assert.equal(
    smsRecipientId({ sender: { id: "sam", role: "client" }, clientId: "sam", trainerId: null }),
    null,
  );
  assert.equal(
    smsRecipientId({ sender: { id: "sam", role: "owner" }, clientId: "sam", trainerId: "chris" }),
    "chris",
  );
  assert.equal(
    smsRecipientId({ sender: { id: "stranger", role: "guest" }, clientId: "sam", trainerId: "chris" }),
    "chris",
  );
  assert.equal(smsRecipientId({ sender: null, clientId: "sam", trainerId: "chris" }), null);

  const held = planTextsForSavedMessage({
    sender: { id: "owner", role: "owner", displayName: BUSINESS_NAME },
    recipient: { id: "sam", role: "client", phone: "+15551110002", optedOut: false, hasConsent: false, declined: false },
    body: "See you",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: true,
  });
  assert.equal(held.clientSms, "disabled");
  assert.equal(held.sms.length, 0);
  assert.equal(held.invite, null);
  assert.equal(held.sms.some((item) => item.toId === "chris"), false);

  const sent = planTextsForSavedMessage({
    sender: { id: "owner", role: "owner", displayName: BUSINESS_NAME },
    recipient: { id: "sam", role: "client", phone: "+15551110002", optedOut: false, hasConsent: true },
    body: "See you",
    originChannel: "app",
    routedTo: "conversation",
    coaches: [],
    includeSms: true,
  });
  assert.equal(sent.sms.length, 1);
  assert.equal(sent.sms[0].toId, "sam");
  assert.equal(sent.clientSms, "send");
});

test("with invites off, a staff message to someone who never answered is held and not texted", () => {
  const book = gym();
  book.person("sam").hasConsent = false;
  const sent = book.sendApp({ fromId: "owner", toId: "sam", text: "Hello", now: T0 });
  assert.equal(sent.sms.length, 0);
  assert.equal(sent.message.smsPending, true);
  assert.equal(book.person("sam").inviteSentAt, null);
});
