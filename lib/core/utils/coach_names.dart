/// The only name a client, or another coach, is allowed to see.
///
/// Uses the coach name when one was entered ("Coach Chris"). Otherwise
/// "Coach" plus the first name. Never the legal first and last name, and
/// never the legal name glued onto the coach name.
String coachPublicName({
  String? coachName,
  String? firstName,
  String? legalName,
}) {
  final chosen = (coachName ?? "").trim();
  if (chosen.isNotEmpty) return chosen;
  final source = (firstName ?? "").trim().isNotEmpty ? firstName!.trim() : (legalName ?? "").trim();
  final first = source.split(RegExp(r"\s+")).firstWhere((p) => p.isNotEmpty, orElse: () => "");
  if (first.isEmpty) return "Coach";
  return "Coach $first";
}

/// "Coach Chris: message". Leaves a body that already has the prefix alone
/// so a save and a reload do not stack the name twice.
String prefixMessage(String senderName, String body) {
  final name = senderName.trim();
  final text = body;
  if (name.isEmpty) return text;
  final prefix = "$name:";
  if (text.trimLeft().startsWith(prefix)) return text;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return "$name:";
  return "$name: $trimmed";
}

/// True when a string a client might see still contains a coach's legal name.
bool exposesLegalCoachName({
  required String shown,
  required String legalName,
  String? coachName,
}) {
  final legal = legalName.trim();
  if (legal.isEmpty) return false;
  final visible = shown.trim();
  if (visible.isEmpty) return false;
  if (coachName != null && visible == coachName.trim()) return false;
  return visible.contains(legal);
}
