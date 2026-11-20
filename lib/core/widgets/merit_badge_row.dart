import "package:flutter/material.dart";
import "../../data/models/earned_badge.dart";
import "../../data/models/merit_badge_def.dart";
import "../theme/app_colors.dart";
import "merit_badge_shield.dart";

/// Active catalog badges for one client, in the same order as the profile
/// "Active Merit Badges" row. Revoked rows and sub-badges are left out.
List<String> activeMeritBadgeKeys(Iterable<EarnedBadge> earnedBadges, String clientId) {
  final earned = <String>{
    for (final badge in earnedBadges)
      if (badge.clientId == clientId && badge.isActive) badge.badgeKey,
  };
  return [for (final def in kMeritBadges) if (earned.contains(def.key)) def.key];
}

/// How many icons fit on one client tile, and how many are left over.
({List<String> shown, int extra}) tileBadgeWindow(List<String> keys, {int max = 4}) {
  if (keys.length <= max) return (shown: keys, extra: 0);
  return (shown: keys.sublist(0, max), extra: keys.length - max);
}

/// Mirrors MeritBadgeRow.jsx — compact horizontal strip of a client's
/// ACTIVE (earned, not revoked) badges only.
class MeritBadgeRow extends StatelessWidget {
  const MeritBadgeRow({super.key, required this.clientId, required this.earnedBadges, this.size = 26});

  final String clientId;
  final List<EarnedBadge> earnedBadges;
  final double size;

  @override
  Widget build(BuildContext context) {
    final keys = activeMeritBadgeKeys(earnedBadges, clientId);
    if (keys.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final key in keys)
          Tooltip(
            message: meritBadgeByKey(key)?.name ?? key,
            child: MeritBadgeShield(badgeKey: key, size: size),
          ),
      ],
    );
  }
}

/// One line of active merit badges for a client tile.
///
/// Same shields as [MeritBadgeRow]. At most [max] icons, then "+N".
/// No badges leaves the line blank.
class ClientTileBadges extends StatelessWidget {
  const ClientTileBadges({
    super.key,
    required this.clientId,
    required this.earnedBadges,
    this.max = 4,
    this.size = 16,
  });

  final String clientId;
  final List<EarnedBadge> earnedBadges;
  final int max;
  final double size;

  @override
  Widget build(BuildContext context) {
    final window = tileBadgeWindow(activeMeritBadgeKeys(earnedBadges, clientId), max: max);
    return SizedBox(
      height: size,
      child: window.shown.isEmpty
          ? const SizedBox.shrink()
          : Row(
              children: [
                for (var i = 0; i < window.shown.length; i++) ...[
                  if (i > 0) const SizedBox(width: 3),
                  Tooltip(
                    message: meritBadgeByKey(window.shown[i])?.name ?? window.shown[i],
                    child: MeritBadgeShield(badgeKey: window.shown[i], size: size),
                  ),
                ],
                if (window.extra > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    "+${window.extra}",
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      color: AppColors.mute,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
