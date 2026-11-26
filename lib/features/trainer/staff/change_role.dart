import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/client_info.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";

/// The two roles the owner can give someone. Owner is never offered.
const kChangeRoleOptions = ["client", "coach"];

String roleLabel(String role) => role == "coach" ? "Coach" : "Client";

/// What the confirmation dialog tells the owner before anything changes.
///
/// Nothing is cancelled or deleted by a role change. The two cases that
/// could surprise the owner are spelled out instead: a client's membership
/// keeps billing until it is cancelled, and a coach's upcoming sessions stay
/// on the schedule.
class RoleChangePlan {
  const RoleChangePlan({
    required this.name,
    required this.from,
    required this.to,
    this.hasMembership = false,
    this.upcomingSessions = 0,
  });

  final String name;
  final String from;
  final String to;

  /// A client who holds a membership or a Stripe subscription.
  final bool hasMembership;

  /// A coach's sessions from today on that are not cancelled.
  final int upcomingSessions;

  String get headline {
    final app = to == "coach" ? "coach" : "client";
    return "$name will become a ${roleLabel(to)} and will see the $app app on next sign-in.";
  }

  List<String> get warnings => [
    if (from == "client" && to == "coach" && hasMembership)
      "$name has an active membership. It keeps billing until you cancel it. Changing the role does not cancel it.",
    if (from == "coach" && to == "client" && upcomingSessions > 0)
      "$name has $upcomingSessions upcoming session${upcomingSessions == 1 ? "" : "s"} as a coach. "
          "They stay on the schedule and are not cancelled, so move or cancel them yourself.",
    "Past sessions, payments and history stay as they are.",
  ];
}

/// Sessions a coach still has coming up. Cancelled ones are not counted.
int upcomingCoachSessions(
  Iterable<Booking> bookings,
  String coachId,
  String today,
) => bookings
    .where(
      (b) =>
          b.trainerId == coachId &&
          b.status != "cancelled" &&
          b.date.compareTo(today) >= 0,
    )
    .length;

bool clientHasMembership(ClientInfo? c) =>
    c != null &&
    (c.heldPlanIds.isNotEmpty || (c.stripeSubscriptionId ?? "").isNotEmpty);

/// Cancel / Confirm. True only when the owner taps Confirm.
Future<bool> confirmRoleChange(
  BuildContext context,
  RoleChangePlan plan,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key("change-role-dialog"),
      backgroundColor: AppColors.card,
      title: const Text("Change role?"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.headline,
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4),
            ),
            for (final w in plan.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  w,
                  style: TextStyle(
                    color: AppColors.mute,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key("change-role-cancel"),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text("Cancel"),
        ),
        TextButton(
          key: const Key("change-role-confirm"),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            "Confirm",
            style: TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
  return ok == true;
}

/// "Change role" for one person, shown to the owner only.
///
/// Used on each coach card on the Staff page and on a client's profile, so a
/// client can be promoted to coach and a coach moved back to client. For
/// anyone but the owner it draws nothing at all.
class ChangeRoleAction extends ConsumerStatefulWidget {
  const ChangeRoleAction({
    super.key,
    required this.profileId,
    required this.name,
    required this.currentRole,
    this.onChanged,
    this.setRole,
  });

  final String profileId;
  final String name;

  /// "client" or "coach". Anything else (the owner) draws nothing.
  final String currentRole;

  /// Runs after the change went through and the lists were refreshed.
  final VoidCallback? onChanged;

  /// Replaces the server call. Only tests pass this.
  final Future<void> Function(String userId, String role)? setRole;

  @override
  ConsumerState<ChangeRoleAction> createState() => _ChangeRoleActionState();
}

class _ChangeRoleActionState extends ConsumerState<ChangeRoleAction> {
  bool _busy = false;

  Future<String?> _pickRole() => showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      key: const Key("change-role-picker"),
      backgroundColor: AppColors.card,
      title: Text("Change role for ${widget.name}"),
      children: [
        for (final role in kChangeRoleOptions)
          SimpleDialogOption(
            key: Key("change-role-option-$role"),
            onPressed: role == widget.currentRole
                ? null
                : () => Navigator.of(ctx).pop(role),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    roleLabel(role),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: role == widget.currentRole ? AppColors.mute : null,
                    ),
                  ),
                ),
                if (role == widget.currentRole)
                  Text(
                    "Current",
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
              ],
            ),
          ),
      ],
    ),
  );

  Future<void> _start() async {
    final picked = await _pickRole();
    if (picked == null || picked == widget.currentRole || !mounted) return;

    final roster = ref.read(trainerRosterProvider);
    ClientInfo? asClient;
    for (final c in roster) {
      if (c.id == widget.profileId) asClient = c;
    }
    final plan = RoleChangePlan(
      name: widget.name,
      from: widget.currentRole,
      to: picked,
      hasMembership: clientHasMembership(asClient),
      upcomingSessions: upcomingCoachSessions(
        ref.read(allBookingsProvider),
        widget.profileId,
        isoToday(),
      ),
    );
    if (!await confirmRoleChange(context, plan) || !mounted) return;

    // Taken now: the lists refresh below can remove this row from the
    // screen, and the confirmation still has to show.
    final messenger = ScaffoldMessenger.of(context);
    final onChanged = widget.onChanged;
    final name = widget.name;
    setState(() => _busy = true);
    try {
      final setRole =
          widget.setRole ??
          ((id, role) => SupabaseService.setUserRole(id, role));
      await setRole(widget.profileId, picked);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst("Exception: ", ""))),
      );
      return;
    }
    // Pull the lists again so the person moves between the client roster
    // and the Staff page right away. Best effort: the change is already
    // saved, and the next refresh picks it up if this one fails.
    try {
      final directory = await SupabaseService.directoryWithContacts();
      ref
          .read(trainerRosterProvider.notifier)
          .setAll(await SupabaseService.rosterFromDirectory(directory));
      ref
          .read(trainersProvider.notifier)
          .setAll(await SupabaseService.trainersFromDirectory(directory));
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          "$name is now a ${roleLabel(picked)}. They'll see the ${picked == "coach" ? "coach" : "client"} app next time they sign in.",
        ),
      ),
    );
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(trainerAuthProvider) != "owner") {
      return const SizedBox.shrink();
    }
    if (!kChangeRoleOptions.contains(widget.currentRole)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: BtnGhost(
        key: Key("change-role-${widget.profileId}"),
        full: true,
        onPressed: _busy ? null : _start,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.userCog, size: 14),
            const SizedBox(width: 8),
            Text(_busy ? "Changing role…" : "Change role"),
          ],
        ),
      ),
    );
  }
}
