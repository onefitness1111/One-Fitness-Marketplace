/// One row of `quiet_nudges`. Written by the morning job, read by the
/// coach and owner dashboards. A text date means the day-3 alert is open
/// until the client logs again.
class QuietNudge {
  const QuietNudge({
    required this.clientId,
    required this.lastActivityOn,
    this.textSentOn,
    this.coachId,
  });

  final String clientId;

  /// yyyy-MM-dd. The last food log or workout, or the day they joined
  /// when they have never logged.
  final String lastActivityOn;

  /// yyyy-MM-dd when the day-3 text and staff alert have gone out.
  final String? textSentOn;
  final String? coachId;

  bool get staffAlertOpen => textSentOn != null && textSentOn!.isNotEmpty;

  static QuietNudge? fromJson(Map<String, dynamic> json) {
    final clientId = json["client_id"]?.toString() ?? "";
    final last = _day(json["last_activity_on"]);
    if (clientId.isEmpty || last == null) return null;
    return QuietNudge(
      clientId: clientId,
      lastActivityOn: last,
      textSentOn: _day(json["text_sent_on"]),
      coachId: json["coach_id"]?.toString(),
    );
  }

  static String? _day(Object? raw) {
    final text = raw?.toString().trim() ?? "";
    if (text.length < 10) return null;
    return text.substring(0, 10);
  }
}
