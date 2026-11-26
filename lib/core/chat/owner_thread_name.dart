import "../utils/chat_channels.dart";

/// What a client sees as the name on a direct thread with the owner. Never
/// the owner's real name. Owner and coach screens are not affected.
const kOwnerThreadNameForClients = "ONE Fitness Market";

/// A staff message in a client's owner thread, as the client should read it.
///
/// Messages carry their sender as a "Name: " prefix. When that name is the
/// owner's (any of [ownerNames]) or a business label, it is shown as
/// "ONE Fitness Market: " instead. Anything else is left as it is.
String ownerThreadTextForClient(String text, {Iterable<String> ownerNames = const []}) {
  final labels = <String>{
    for (final n in ownerNames)
      if (n.trim().isNotEmpty) n.trim(),
    kMarketplaceName,
    "ONE Fitness",
    kOwnerThreadNameForClients,
  }.toList()
    // Longest first, so "ONE Fitness Marketplace" wins over "ONE Fitness".
    ..sort((a, b) => b.length.compareTo(a.length));
  final lead = text.length - text.trimLeft().length;
  final body = text.substring(lead);
  for (final label in labels) {
    final prefix = "$label:";
    if (body.startsWith(prefix)) {
      final rest = body.substring(prefix.length).trimLeft();
      return rest.isEmpty ? "$kOwnerThreadNameForClients:" : "$kOwnerThreadNameForClients: $rest";
    }
  }
  return text;
}
