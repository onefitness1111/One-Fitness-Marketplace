/// Who a broadcast may reach, and which channels are allowed.
///
/// The only combinations are app chat, app chat plus a text, or email by
/// itself. A text is never sent on its own, and email is never mixed with
/// the other two. A coach reaches only their own clients. The owner reaches
/// every client. The server applies the same rules again before anything
/// is sent.

enum BroadcastChannel { app, appSms, email }

const broadcastChannelWire = {
  BroadcastChannel.app: "app",
  BroadcastChannel.appSms: "app_sms",
  BroadcastChannel.email: "email",
};

const broadcastChannelLabel = {
  BroadcastChannel.app: "App chat only",
  BroadcastChannel.appSms: "App chat and text",
  BroadcastChannel.email: "Email only",
};

/// Null when the choice is not one of the three allowed combinations.
BroadcastChannel? broadcastChannelFromWire(String? raw) {
  final value = (raw ?? "").trim();
  for (final entry in broadcastChannelWire.entries) {
    if (entry.value == value) return entry.key;
  }
  return null;
}

/// A set of chat chips is a broadcast only for the three allowed shapes.
BroadcastChannel? broadcastChannelFromSet(Set<String> channels) {
  final names = channels.map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
  if (names.length == 1 && names.contains("inapp")) return BroadcastChannel.app;
  if (names.length == 2 && names.contains("inapp") && names.contains("sms")) return BroadcastChannel.appSms;
  if (names.length == 1 && names.contains("email")) return BroadcastChannel.email;
  return null;
}

bool broadcastChannelAllowed(Set<String> channels) => broadcastChannelFromSet(channels) != null;

class BroadcastClient {
  const BroadcastClient({
    required this.id,
    this.primaryTrainerId,
    this.phone = "",
    this.email = "",
    this.smsOptIn = false,
    this.smsOptedOut = false,
  });

  final String id;
  final String? primaryTrainerId;
  final String phone;
  final String email;
  final bool smsOptIn;
  final bool smsOptedOut;

  bool get hasPhone => phone.trim().isNotEmpty;
  bool get hasEmail => email.trim().isNotEmpty;
  bool get canText => hasPhone && smsOptIn && !smsOptedOut;
}

class BroadcastScope {
  const BroadcastScope({required this.allowed, required this.refused});

  final List<BroadcastClient> allowed;
  final List<String> refused;
}

/// [all] ignores [requestedIds] and takes everyone this sender may reach.
/// A coach's "everyone" is still only their own clients.
BroadcastScope scopeBroadcast({
  required bool senderIsOwner,
  required String senderId,
  required bool all,
  required List<String> requestedIds,
  required List<BroadcastClient> clients,
}) {
  final mine = clients.where((c) {
    if (senderIsOwner) return true;
    final coach = (c.primaryTrainerId ?? "").trim();
    return senderId.isNotEmpty && coach == senderId;
  }).toList();
  if (all) return BroadcastScope(allowed: mine, refused: const []);
  final byId = {for (final c in mine) c.id: c};
  final allowed = <BroadcastClient>[];
  final refused = <String>[];
  for (final id in requestedIds) {
    final person = byId[id];
    if (person == null) {
      if (id.trim().isNotEmpty) refused.add(id);
    } else {
      allowed.add(person);
    }
  }
  return BroadcastScope(allowed: allowed, refused: refused);
}

/// Texts are quiet before 8:00am and from 9:00pm Pacific.
bool smsQuietHours(DateTime nowUtc) {
  final pacific = _pacific(nowUtc.toUtc());
  return pacific.hour < 8 || pacific.hour >= 21;
}

class BroadcastPreview {
  const BroadcastPreview({
    required this.recipients,
    required this.app,
    required this.sms,
    required this.email,
    required this.skippedNoPhone,
    required this.skippedOptOut,
    required this.skippedQuietHours,
    required this.skippedNoEmail,
    required this.refused,
  });

  final int recipients;
  final int app;
  final int sms;
  final int email;
  final int skippedNoPhone;
  final int skippedOptOut;
  final int skippedQuietHours;
  final int skippedNoEmail;
  final int refused;
}

BroadcastPreview previewBroadcast({
  required BroadcastChannel channel,
  required List<BroadcastClient> recipients,
  required DateTime nowUtc,
  int refused = 0,
}) {
  var sms = 0;
  var noPhone = 0;
  var optedOut = 0;
  var quiet = 0;
  var email = 0;
  var noEmail = 0;
  final quietNow = smsQuietHours(nowUtc);
  for (final person in recipients) {
    if (channel == BroadcastChannel.email) {
      if (person.hasEmail) {
        email++;
      } else {
        noEmail++;
      }
      continue;
    }
    if (channel == BroadcastChannel.appSms) {
      if (!person.hasPhone) {
        noPhone++;
      } else if (!person.smsOptIn || person.smsOptedOut) {
        optedOut++;
      } else if (quietNow) {
        quiet++;
      } else {
        sms++;
      }
    }
  }
  final app = channel == BroadcastChannel.email ? 0 : recipients.length;
  return BroadcastPreview(
    recipients: recipients.length,
    app: app,
    sms: sms,
    email: email,
    skippedNoPhone: noPhone,
    skippedOptOut: optedOut,
    skippedQuietHours: quiet,
    skippedNoEmail: noEmail,
    refused: refused,
  );
}

DateTime _pacific(DateTime utc) {
  final year = utc.year;
  final start = DateTime.utc(year, 3, _nthSunday(year, 3, 2), 10);
  final end = DateTime.utc(year, 11, _nthSunday(year, 11, 1), 9);
  final daylight = !utc.isBefore(start) && utc.isBefore(end);
  return utc.add(Duration(hours: daylight ? -7 : -8));
}

int _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final offset = (DateTime.sunday - first.weekday) % 7;
  return 1 + offset + (n - 1) * 7;
}
