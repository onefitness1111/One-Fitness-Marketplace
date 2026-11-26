import "coach_names.dart";

/// Who should hear about something that happened to a client.
///
/// A session notifies the coach who ran it. Anything without a session
/// coach, such as a sign-up, notifies every coach. The owner hears
/// internal updates (photos, measurements, programs, intake). The client
/// always gets a confirmation of what they themselves did.
class NotifyAudience {
  const NotifyAudience({required this.clientIds, required this.coachIds, required this.ownerIds});
  final List<String> clientIds;
  final List<String> coachIds;
  final List<String> ownerIds;
}

class CoachAudience {
  const CoachAudience({
    required this.id,
    required this.location,
    this.publicName,
  });
  final String id;
  final String? location;
  final String? publicName;
}

/// [eventTrainerId] is the coach on the booking or the coach who created
/// the challenge. When that is empty, every coach is notified.
NotifyAudience audienceFor({
  required String clientId,
  required List<CoachAudience> coaches,
  required List<String> ownerIds,
  String? eventTrainerId,
  bool internal = false,
}) {
  if (internal) {
    return NotifyAudience(clientIds: const [], coachIds: const [], ownerIds: ownerIds);
  }
  final heard = <String>{};
  final sessionCoach = (eventTrainerId ?? "").trim();
  if (sessionCoach.isNotEmpty) {
    for (final coach in coaches) {
      if (coach.id == sessionCoach) heard.add(coach.id);
    }
  } else {
    for (final coach in coaches) {
      heard.add(coach.id);
    }
  }
  return NotifyAudience(
    clientIds: clientId.isEmpty ? const [] : [clientId],
    coachIds: heard.toList(),
    ownerIds: const [],
  );
}

/// Messages use the coach's public name, never a legal name.
String coachLabel(CoachAudience coach) => coachPublicName(coachName: coach.publicName);
