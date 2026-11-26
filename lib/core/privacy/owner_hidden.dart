/// The owner is never shown to clients as a profile. Clients reach the owner
/// only through the ONE Fitness chat thread or by email. A coach profile that
/// belongs to the same person (Coach Chris) is its own coach row with its own
/// id, so it is not affected by this.

/// True when [profileId] is one of the owner profiles.
bool isOwnerProfileId(String profileId, Iterable<String> ownerIds) {
  final id = profileId.trim();
  if (id.isEmpty) return false;
  return ownerIds.any((o) => o.trim() == id);
}
