/// Mirrors one row in `merit_badges` — a client's earned (and possibly
/// later revoked) Merit Badge.
class EarnedBadge {
  const EarnedBadge({
    required this.id,
    required this.clientId,
    required this.badgeKey,
    required this.earnedAt, // ISO date
    this.earnedMethod = "automatic", // "automatic" | "coach"
    this.grantedByUserId,
    this.note,
    this.revokedAt,
    this.revokedByUserId,
    this.celebratedAt,
  });

  final String id;
  final String clientId;
  final String badgeKey;
  final String earnedAt;
  final String earnedMethod;
  final String? grantedByUserId;
  final String? note;
  final String? revokedAt;
  final String? revokedByUserId;

  /// Set once the client has seen the "Merit Badge earned!" popup.
  /// Null means they have not seen it yet.
  final String? celebratedAt;

  bool get isActive => revokedAt == null;

  /// Badges earned before this release are not popped up again.
  bool get awaitingCelebration =>
      isActive && celebratedAt == null && earnedAt.compareTo("2026-11-18") >= 0;

  EarnedBadge copyWith({String? revokedAt, String? revokedByUserId}) => EarnedBadge(
        id: id,
        clientId: clientId,
        badgeKey: badgeKey,
        earnedAt: earnedAt,
        earnedMethod: earnedMethod,
        grantedByUserId: grantedByUserId,
        note: note,
        revokedAt: revokedAt ?? this.revokedAt,
        revokedByUserId: revokedByUserId ?? this.revokedByUserId,
        celebratedAt: celebratedAt,
      );
}
