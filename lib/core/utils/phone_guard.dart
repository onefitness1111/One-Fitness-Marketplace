import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../data/providers/platform_settings_provider.dart";
import "../../data/providers/trainer_providers.dart";

/// Keeps the gym's own support number (Customize Platform → Location) from
/// being saved as a client's or coach's personal phone. Texts and calls
/// meant for that person would otherwise go to the gym's line instead.
///
/// The owner is exempt, and so is a coach who is already signed in. Coaches
/// may use the gym's number. A client may not: texts meant for them would
/// land on the gym's line, and a client and a coach must not share a number.

/// Digits only, with a leading US country code dropped, so "818-223-7001",
/// "(818) 223 7001" and "+1 818 223 7001" all compare equal.
String _digits(String raw) {
  final d = raw.replaceAll(RegExp(r"\D"), "");
  return d.length == 11 && d.startsWith("1") ? d.substring(1) : d;
}

bool isGymSupportNumber(String phone, String supportPhone) {
  final a = _digits(phone);
  return a.length >= 7 && a == _digits(supportPhone);
}

const kGymNumberError =
    "That's the gym's own number. Please enter your own phone number.";

/// [kGymNumberError] when a client tries to save the gym's number.
/// A signed-in coach or the owner may use that number.
String? gymNumberError(BuildContext context, String phone) {
  final container = ProviderScope.containerOf(context, listen: false);
  final auth = container.read(trainerAuthProvider);
  if (auth != null && auth.isNotEmpty) return null;
  final support = container.read(platformSettingsProvider).supportPhone;
  return isGymSupportNumber(phone, support) ? kGymNumberError : null;
}
