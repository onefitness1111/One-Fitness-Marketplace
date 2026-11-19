/// Reads that used to hit columns the privacy rules hide.
///
/// Phone comes back from profile_contact_for. Chat intro and SMS consent
/// come back from my_messaging_prefs, which only returns the signed-in row.

String? phoneFromContactRows(dynamic rows) {
  final row = firstRpcRow(rows);
  final phone = row?["phone"];
  if (phone is! String) return null;
  final trimmed = phone.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, dynamic>? firstRpcRow(dynamic rows) {
  if (rows is Map) return Map<String, dynamic>.from(rows);
  if (rows is List && rows.isNotEmpty && rows.first is Map) {
    return Map<String, dynamic>.from(rows.first as Map);
  }
  return null;
}

/// True when this person already tapped through the chat explanation.
bool chatIntroSeenFromPrefs(Map<String, dynamic>? prefs) =>
    prefs?["chat_intro_seen_at"] != null;

/// True or false when the profile row answers the question. Null when it
/// does not, so the caller can still look at the older client opt-in flag.
bool? smsConsentFromPrefs(Map<String, dynamic>? prefs) {
  if (prefs == null) return null;
  if (prefs["sms_opted_out"] == true) return false;
  if (prefs["sms_consent_at"] != null) return true;
  return null;
}
