import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../data/providers/coach_permissions_provider.dart";
import "../../../data/providers/trainer_providers.dart";

/// The owner's on/off switches for one coach, shown on that coach's card on
/// the Staff page. Owner only: it draws nothing for anyone else, and the
/// database refuses a change from anyone else too.
///
/// A new coach starts with everything off. Turning one on takes effect the
/// next time that coach opens the app or its data refreshes.
class CoachPermissionSwitches extends ConsumerWidget {
  const CoachPermissionSwitches({super.key, required this.coachId, required this.coachName, this.save});

  final String coachId;
  final String coachName;

  /// How a change is saved. Defaults to the owner-only database setter; a
  /// test passes its own.
  final Future<void> Function(String coachId, CoachPermission permission, bool allowed)? save;

  Future<void> _set(BuildContext context, WidgetRef ref, CoachPermission p, bool value) async {
    final notifier = ref.read(coachPermissionsProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    notifier.setOne(coachId, p, value);
    try {
      final custom = save;
      if (custom != null) {
        await custom(coachId, p, value);
      } else {
        await SupabaseService.setCoachPermission(coachId: coachId, permission: p.column, allowed: value);
      }
    } catch (_) {
      notifier.setOne(coachId, p, !value);
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't save that change. Try again.")),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(trainerAuthProvider) != "owner") return const SizedBox.shrink();
    final loaded = ref.watch(coachPermissionsProvider).loaded;
    final perms = ref.watch(coachPermissionsForProvider(coachId));
    return Container(
      key: Key("perm-section-$coachId"),
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.keyRound, size: 14, color: AppColors.gold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "What $coachName can do",
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.txt),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "Everything starts off for a new coach. You always can do all of it.",
            style: TextStyle(fontSize: 11, color: AppColors.mute),
          ),
          const SizedBox(height: 6),
          for (final p in CoachPermission.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.label,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.txt),
                        ),
                        Text(p.help, style: TextStyle(fontSize: 11, color: AppColors.mute)),
                      ],
                    ),
                  ),
                  Switch(
                    key: Key("perm-switch-$coachId-${p.column}"),
                    value: perms.allows(p),
                    activeThumbColor: AppColors.gold,
                    activeTrackColor: AppColors.gold.withValues(alpha: 0.35),
                    inactiveThumbColor: AppColors.mute,
                    inactiveTrackColor: AppColors.line,
                    onChanged: loaded ? (v) => _set(context, ref, p, v) : null,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            "Reports of their own sessions are always on for every coach.",
            style: TextStyle(fontSize: 11, color: AppColors.mute),
          ),
        ],
      ),
    );
  }
}
