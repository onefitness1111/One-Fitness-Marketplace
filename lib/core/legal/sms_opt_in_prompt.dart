import "dart:async";

/// Who should see the one-tap "Get texts from your coach?" prompt, and
/// who an owner may notify about it.
///
/// A client qualifies when they have not agreed (`sms_opt_in` false or
/// null) and they have not opted out. Coach assignment is not an input.
/// "Not now" hides the passive card for 14 days. A push the person tapped
/// still opens the prompt, because that tap is them asking to see it.
/// Someone who opted out never sees it, including from that push.

const String kSmsOptInPromptTitle = "Get texts from your coach?";
const String kSmsOptInPromptYes = "Yes, text me";
const String kSmsOptInPromptLater = "Not now";

const String kSmsOptInPushTitle = "Tap to get texts from your coach";
const String kSmsOptInPushBody = "Open the app to agree. No text is sent until you say yes.";
const String kSmsOptInPushKind = "sms-opt-in";

const int kSmsOptInSnoozeDays = 14;
const String kSmsOptInHideUntilKey = "sms_opt_in_hide_until_v1";

/// Set when a notification should open the prompt. The client shell reads
/// it once it is on screen. A broadcast stream drops events with no
/// listener, so [pending] covers a tap that arrived before the shell.
class SmsOptInPromptBus {
  static final StreamController<void> _opens = StreamController<void>.broadcast();
  static bool pending = false;

  static Stream<void> get opens => _opens.stream;

  static void open() {
    pending = true;
    _opens.add(null);
  }

  static bool takePending() {
    final had = pending;
    pending = false;
    return had;
  }
}

DateTime smsOptInHiddenUntil(DateTime now) => now.add(const Duration(days: kSmsOptInSnoozeDays));

bool showSmsOptInPrompt({
  required bool? smsOptIn,
  required bool smsOptedOut,
  DateTime? hiddenUntil,
  required DateTime now,
  bool openedFromPush = false,
}) {
  if (smsOptedOut) return false;
  if (smsOptIn == true) return false;
  if (!openedFromPush && hiddenUntil != null && now.isBefore(hiddenUntil)) return false;
  return true;
}

/// One person the owner might notify.
class SmsPromptPerson {
  const SmsPromptPerson({
    required this.id,
    required this.smsOptIn,
    required this.smsOptedOut,
  });

  final String id;
  final bool? smsOptIn;
  final bool smsOptedOut;
}

List<String> smsOptInPromptRecipientIds(List<SmsPromptPerson> people) {
  final ids = <String>[];
  for (final person in people) {
    final show = showSmsOptInPrompt(
      smsOptIn: person.smsOptIn,
      smsOptedOut: person.smsOptedOut,
      now: DateTime.utc(2026, 11, 21),
    );
    if (show && person.id.isNotEmpty) ids.add(person.id);
  }
  return ids;
}

/// The push the owner function sends. `sms` is false on purpose: these
/// clients have not consented, so the payload must not ask for a text.
Map<String, Object> smsOptInOwnerPush() => {
      "title": kSmsOptInPushTitle,
      "body": kSmsOptInPushBody,
      "sms": false,
      "data": {
        "kind": kSmsOptInPushKind,
        "screen": "dashboard",
      },
    };

bool smsOptInPushOpensPrompt(Map<String, dynamic> data) {
  final kind = data["kind"]?.toString() ?? "";
  final screen = data["screen"]?.toString() ?? "";
  return kind == kSmsOptInPushKind || screen == kSmsOptInPushKind;
}
