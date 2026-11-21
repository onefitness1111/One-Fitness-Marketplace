/// How a chat message gets delivered, as an independent set rather than a
/// single choice.
///
/// It used to be a three-way pick — Email, "In App / SMS", or Both — which
/// welded the app thread to a text message. A client who had no phone
/// number, or didn't want to hand one over, was pushed to Email to use the
/// app's own chat at all: choosing "In App" meant agreeing to be texted,
/// and the screen demanded a number before it would let them.
///
/// The three are now picked independently, so In app alone is a valid
/// choice and asks for nothing. SMS is the only one that needs a phone
/// number, and it's the only one that asks for it.
/// The name the business contact goes by everywhere in chat. It is a business
/// contact, not a location, and has no SMS channel.
const kMarketplaceName = "ONE Fitness Marketplace";

enum ChatChannel {
  /// Lands in the recipient's thread and pushes their device. The message
  /// is stored either way — the thread IS the log — so what this adds is
  /// the notification.
  inapp,

  /// Also texted, via Twilio. Needs a number on file; replies come back
  /// into the same thread (see the sms-inbound function).
  sms,

  /// Also emailed.
  email,
}

/// Picker order, and the order [encodeChannels] writes. Fixed so a stored
/// value is comparable as a string and the chips never reshuffle.
const chatChannelOrder = [ChatChannel.inapp, ChatChannel.sms, ChatChannel.email];

const chatChannelLabels = {
  ChatChannel.inapp: "In app",
  ChatChannel.sms: "SMS",
  ChatChannel.email: "Email",
};

/// What a new chat starts on: the app thread and a text, both on.
/// Email is separate and is not saved on the message.
/// The stored form is [defaultChatChannelValue], "inapp,sms".
const defaultChatChannels = {ChatChannel.inapp, ChatChannel.sms};

/// Wire form of [defaultChatChannels]. Also the marker that a saved
/// preference has already been brought up to this default once.
const defaultChatChannelValue = "inapp,sms";

const chatChannelDefaultMarker = defaultChatChannelValue;

/// Result of reading a saved picker. [writeBack] means the caller should
/// store [channels] and [chatChannelDefaultMarker] so a later choice,
/// including turning SMS off, is not overwritten on the next open.
class ResolvedChatChannels {
  const ResolvedChatChannels({required this.channels, required this.writeBack});

  final Set<ChatChannel> channels;
  final bool writeBack;
}

/// First open after this default, a saved set gains In app and SMS.
/// Email that was already on stays on. Once the marker is stored, the
/// saved set is used as the person left it.
ResolvedChatChannels resolveSavedChatChannels(String? stored, String? appliedMarker) {
  final saved = decodeChannels(stored);
  if (appliedMarker == chatChannelDefaultMarker) {
    return ResolvedChatChannels(
      channels: saved.isEmpty ? {...defaultChatChannels} : saved,
      writeBack: false,
    );
  }
  return ResolvedChatChannels(
    channels: {...saved, ChatChannel.inapp, ChatChannel.sms},
    writeBack: true,
  );
}

/// A client who declines the SMS consent prompt does not keep SMS selected.
Set<ChatChannel> channelsAfterSmsChoice(
  Set<ChatChannel> current,
  Set<ChatChannel> next, {
  required bool smsAllowed,
}) {
  final turnedSmsOn = next.contains(ChatChannel.sms) && !current.contains(ChatChannel.sms);
  if (!turnedSmsOn || smsAllowed) return next;
  final stripped = {...next}..remove(ChatChannel.sms);
  return stripped.isEmpty ? {ChatChannel.inapp} : stripped;
}

/// Canonical wire form for `messages.channel` and the remembered
/// preference: the selected names in [chatChannelOrder], comma-joined —
/// "inapp", "inapp,sms", "inapp,sms,email".
///
/// An empty set would mean "deliver nowhere", which no caller should reach
/// (the picker requires one); it encodes as the default rather than as an
/// empty string so a bad write can't produce an unreadable row.
String encodeChannels(Set<ChatChannel> channels) {
  final selected = chatChannelOrder.where(channels.contains);
  if (selected.isEmpty) return encodeChannels(defaultChatChannels);
  return selected.map((c) => c.name).join(",");
}

/// Reads [encodeChannels]' form, and every value this column has ever held.
///
/// The column is plain text with no constraint, written by three different
/// places over time, so the old spellings are still in the table and still
/// render in threads:
///
///   "email"     → Email only
///   "inappSms"  → the old welded pair
///   "inapp"     → in-app only
///   "both"      → all three ("both" meant emailed AND texted, and every
///                 message was in the thread regardless)
///   "sms"       → written by sms-inbound/twilio-inbound for a reply that
///                 arrived as a text
///
/// Anything unrecognised — including null, for rows stored before the
/// column existed — comes back empty, which the badge renders as nothing
/// rather than as a guess.
Set<ChatChannel> decodeChannels(String? stored) {
  final raw = (stored ?? "").trim();
  if (raw.isEmpty) return const {};
  switch (raw) {
    case "inappSms":
      return const {ChatChannel.inapp, ChatChannel.sms};
    case "both":
      return const {ChatChannel.inapp, ChatChannel.sms, ChatChannel.email};
  }
  final out = <ChatChannel>{};
  for (final token in raw.split(",")) {
    final name = token.trim();
    for (final c in ChatChannel.values) {
      if (c.name == name) out.add(c);
    }
  }
  return out;
}

/// "In app · SMS" — for the thread's context bar, in picker order.
String chatChannelsLabel(Set<ChatChannel> channels) {
  final selected = chatChannelOrder.where(channels.contains).map((c) => chatChannelLabels[c]!);
  return selected.isEmpty ? chatChannelLabels[ChatChannel.inapp]! : selected.join(" · ");
}

/// The one gate that still needs a phone number. Everything else about a
/// chat has to work without one.
bool channelsNeedPhone(Set<ChatChannel> channels) => channels.contains(ChatChannel.sms);

/// A send has to reach somewhere, so the picker can't be emptied. This is
/// the only rule it enforces.
bool canSendOn(Set<ChatChannel> channels) => channels.isNotEmpty;

/// Toggling a chip, with that one rule applied: turning the last one off
/// is a no-op, not an unsendable state.
Set<ChatChannel> toggleChannel(Set<ChatChannel> channels, ChatChannel channel) {
  if (!channels.contains(channel)) return {...channels, channel};
  if (channels.length == 1) return channels;
  return {...channels}..remove(channel);
}
