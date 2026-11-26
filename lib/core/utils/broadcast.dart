/// Who a broadcast may reach, and which channels are allowed.
///
/// In app, SMS, and Email can be combined. A text still goes out only when
/// that client can receive one. Email is its own send. A coach and the owner
/// both reach every client. The server applies the same rules again before
/// anything is sent.

/// One mix of the three send chips. Empty is not a send.
class BroadcastWays {
  const BroadcastWays({this.app = false, this.sms = false, this.email = false});

  final bool app;
  final bool sms;
  final bool email;

  bool get isEmpty => !app && !sms && !email;

  static const appOnly = BroadcastWays(app: true);

  @override
  bool operator ==(Object other) =>
      other is BroadcastWays && other.app == app && other.sms == sms && other.email == email;

  @override
  int get hashCode => Object.hash(app, sms, email);

  List<String> get wire => [
        if (app) "inapp",
        if (sms) "sms",
        if (email) "email",
      ];
}

BroadcastWays broadcastWaysFromSet(Set<String> channels) {
  final names = channels.map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
  return BroadcastWays(
    app: names.contains("inapp"),
    sms: names.contains("sms"),
    email: names.contains("email"),
  );
}

bool broadcastWaysAllowed(Set<String> channels) => !broadcastWaysFromSet(channels).isEmpty;

/// The older single-value wire, when the mix is exactly one of those three.
/// Mixed selections travel as the chip names instead.
String? broadcastLegacyWire(BroadcastWays ways) {
  if (ways.app && !ways.sms && !ways.email) return "app";
  if (ways.app && ways.sms && !ways.email) return "app_sms";
  if (!ways.app && !ways.sms && ways.email) return "email";
  return null;
}

/// What `broadcast-message` puts in the response `channel` field.
/// Old apps read "app", "app_sms", or "email". Anything else is the chip list.
String broadcastSummaryChannel(BroadcastWays ways) => broadcastLegacyWire(ways) ?? ways.wire.join(",");

/// Broadcast label. Newlines become spaces, the ends are trimmed, and the
/// result is at most 40 characters. Empty means the old coach-name prefix.
String sanitizeGroupName(String? raw) {
  final cleaned = (raw ?? "").replaceAll(RegExp(r"[\r\n\t]+"), " ").replaceAll(RegExp(r"\s+"), " ").trim();
  if (cleaned.isEmpty) return "";
  return cleaned.length <= 40 ? cleaned : cleaned.substring(0, 40).trimRight();
}

class BroadcastClient {
  const BroadcastClient({
    required this.id,
    this.phone = "",
    this.email = "",
    this.smsOptIn = false,
    this.smsOptedOut = false,
  });

  final String id;
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
/// A coach reaches every client. The owner does too.
BroadcastScope scopeBroadcast({
  required bool senderIsOwner,
  required String senderId,
  required bool all,
  required List<String> requestedIds,
  required List<BroadcastClient> clients,
}) {
  final mine = clients.where((_) {
    if (senderIsOwner) return true;
    return senderId.trim().isNotEmpty;
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
  required BroadcastWays ways,
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
    if (ways.sms) {
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
    if (ways.email) {
      if (person.hasEmail) {
        email++;
      } else {
        noEmail++;
      }
    }
  }
  final app = ways.app ? recipients.length : 0;
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
