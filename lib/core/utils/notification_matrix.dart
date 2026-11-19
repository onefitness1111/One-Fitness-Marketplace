import "coach_names.dart";

/// Who should hear about something that happened to a client.
///
/// A coach hears it only when it is their own session, they are that
/// client's coach, or it happened at their location. A coach in another
/// location hears nothing. The owner hears internal updates (photos,
/// measurements, programs, intake). The client always gets a confirmation
/// of what they themselves did.
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

/// [eventTrainerId] is the coach on the booking or the coach who started
/// the challenge. [eventLocation] is where that session is. [primaryTrainerId]
/// is the client's own coach. [clientLocation] is the client's home location
/// or city, used when an event has no session of its own (a sign-up).
NotifyAudience audienceFor({
  required String clientId,
  required List<CoachAudience> coaches,
  required List<String> ownerIds,
  String? eventTrainerId,
  String? eventLocation,
  String? primaryTrainerId,
  String? clientLocation,
  bool internal = false,
}) {
  if (internal) {
    return NotifyAudience(clientIds: const [], coachIds: const [], ownerIds: ownerIds);
  }
  final heard = <String>{};
  final place = _norm(eventLocation);
  final home = _norm(clientLocation);
  for (final coach in coaches) {
    if (eventTrainerId != null && eventTrainerId.isNotEmpty) {
      if (coach.id == eventTrainerId) heard.add(coach.id);
      continue;
    }
    if (primaryTrainerId != null && coach.id == primaryTrainerId) {
      heard.add(coach.id);
      continue;
    }
    final coachPlace = _norm(coach.location);
    if (coachPlace.isNotEmpty && (coachPlace == place || coachPlace == home)) {
      heard.add(coach.id);
    }
  }
  return NotifyAudience(
    clientIds: clientId.isEmpty ? const [] : [clientId],
    coachIds: heard.toList(),
    ownerIds: const [],
  );
}

String _norm(String? value) => (value ?? "").trim().toLowerCase();

/// Messages use the coach's public name, never a legal name.
String coachLabel(CoachAudience coach) => coachPublicName(coachName: coach.publicName);

bool sameLocation(String? a, String? b) {
  final left = _norm(a);
  final right = _norm(b);
  return left.isNotEmpty && left == right;
}
