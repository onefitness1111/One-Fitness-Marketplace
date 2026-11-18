import "package:flutter/material.dart";
import "../theme/app_colors.dart";
import "../utils/coach_merit_badge_utils.dart";

/// Mirrors merit_badge_shield.dart's [MeritBadgeShield] — same
/// grayscale-when-not-yet-earned treatment, own image set (see
/// [kCoachBadgeImagePaths]) since Coach Merit Badges are a separate system
/// from the client-facing one that widget renders.
class CoachBadgeShield extends StatelessWidget {
  const CoachBadgeShield({super.key, required this.badgeKey, this.size = 44, this.grayscale = false});

  final String badgeKey;
  final double size;
  final bool grayscale;

  @override
  Widget build(BuildContext context) {
    final path = kCoachBadgeImagePaths[badgeKey];
    if (path == null) {
      final letter = coachBadgeLabel(badgeKey);
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border.all(color: grayscale ? AppColors.line : AppColors.txt),
          shape: BoxShape.circle,
        ),
        child: Text(
          letter.isEmpty ? "?" : letter[0].toUpperCase(),
          style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w800, fontSize: size * 0.38),
        ),
      );
    }
    final image = Image.asset(path, width: size, height: size, fit: BoxFit.contain);
    if (!grayscale) return image;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: Opacity(opacity: 0.75, child: image),
    );
  }
}
