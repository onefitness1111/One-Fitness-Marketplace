import "package:flutter/material.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/membership_rollover.dart";
import "../../../core/utils/membership_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/client_info.dart";
import "../../../data/models/client_plan.dart";
import "../../../data/models/membership_plan.dart";

/// Session count and rollover limit for each membership this client is on.
///
/// Both numbers are stored on that plan entry. Changing one membership
/// does not change another, and does not change any other client.
class PlanAllowances extends StatelessWidget {
  const PlanAllowances({
    super.key,
    required this.info,
    required this.plans,
    required this.bookings,
    required this.onChanged,
  });

  final ClientInfo info;
  final List<MembershipPlan> plans;
  final List<Booking> bookings;
  final void Function(ClientInfo next) onChanged;

  @override
  Widget build(BuildContext context) {
    final memberships = activeMembershipPlans(info, plans);
    if (memberships.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final plan in memberships)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _PlanAllowanceCard(
              key: ValueKey(plan.id),
              info: info,
              plan: plan,
              bookings: bookings,
              onChanged: onChanged,
            ),
          ),
      ],
    );
  }
}

class _PlanAllowanceCard extends StatefulWidget {
  const _PlanAllowanceCard({
    super.key,
    required this.info,
    required this.plan,
    required this.bookings,
    required this.onChanged,
  });

  final ClientInfo info;
  final MembershipPlan plan;
  final List<Booking> bookings;
  final void Function(ClientInfo next) onChanged;

  @override
  State<_PlanAllowanceCard> createState() => _PlanAllowanceCardState();
}

class _PlanAllowanceCardState extends State<_PlanAllowanceCard> {
  late final TextEditingController _remaining;
  late final TextEditingController _rollover;
  late int _choice;
  bool _busy = false;
  String? _error;

  ClientPlanEnrollment? get _enrollment => activeEnrollment(widget.info, widget.plan.id);

  int get _used => sessionsUsedThisPeriod(widget.info, widget.plan, widget.bookings);

  String get _month => isoToday().substring(0, 7);

  int get _rolled => rolloverSessionsFor(widget.info, widget.plan);

  int get _planRemaining {
    final base = (widget.plan.maxSessions ?? 0) + _rolled - _used;
    return base < 0 ? 0 : base;
  }

  @override
  void initState() {
    super.initState();
    final custom = _enrollment?.rolloverMaxOverride;
    _choice = custom == null ? 0 : 1;
    _rollover = TextEditingController(text: custom == null ? "" : "$custom");
    final set = sessionOverrideIsSet(widget.info, widget.plan, _month);
    final left = set ? (effectiveMaxSessions(widget.info, widget.plan) - _used) : null;
    _remaining = TextEditingController(text: left == null ? "" : "${left < 0 ? 0 : left}");
  }

  @override
  void dispose() {
    _remaining.dispose();
    _rollover.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final custom = _choice == 1;
    int? roll;
    if (custom) {
      final text = _rollover.text.trim();
      if (text.isEmpty) {
        setState(() => _error = "Enter how many unused sessions roll over, or switch back to the membership's limit. 0 means none.");
        return;
      }
      roll = int.tryParse(text) ?? 0;
    }
    final remainingText = _remaining.text.trim();
    final clearSessions = remainingText.isEmpty;
    final desired = int.tryParse(remainingText) ?? 0;
    final base = overrideBaseForRemaining(desiredRemaining: desired, used: _used, rollover: _rolled);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final nextPlans = withPlanAllowance(
        widget.info.plans,
        planId: widget.plan.id,
        today: isoToday(),
        touchSessions: true,
        clearSessions: clearSessions,
        maxSessionsOverride: base,
        maxSessionsOverrideMonth: _month,
        touchRollover: true,
        clearRollover: !custom,
        rolloverMaxOverride: roll,
      );
      await SupabaseService.updateClientPlans(widget.info.id, nextPlans);
      if (widget.info.sessionCountOverride != null) {
        await SupabaseService.updateClientRow(widget.info.id, clearSessionCountOverride: true);
      }
      widget.onChanged(widget.info.copyWith(plans: nextPlans, clearSessionCountOverride: true));
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't save — check your connection and try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cap = rolloverCap(widget.plan, null);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.plan.name.toUpperCase(),
            style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          const Text(
            "This client only",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            "REMAINING SESSIONS",
            style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1),
          ),
          const SizedBox(height: 6),
          AppField(
            controller: _remaining,
            kind: FieldKind.integer,
            placeholder: "$_planRemaining",
          ),
          const SizedBox(height: 6),
          Text(
            "Blank uses this membership's count. A number here is only for ${widget.plan.name}, and only this month. It does not carry to another membership.",
            style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
          ),
          const SizedBox(height: 14),
          Text(
            "ROLLOVER LIMIT",
            style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1),
          ),
          const SizedBox(height: 6),
          SegmentedToggle(
            labels: const ["Plan limit", "This client"],
            index: _choice,
            onChanged: (i) => setState(() {
              _choice = i;
              _error = null;
            }),
          ),
          const SizedBox(height: 8),
          if (_choice == 1) ...[
            AppField(
              controller: _rollover,
              kind: FieldKind.integer,
              placeholder: "$cap",
            ),
            const SizedBox(height: 6),
            Text(
              "How many unused sessions roll over for ${widget.plan.name}. 0 means none. Other clients are not changed.",
              style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
            ),
          ] else
            Text(
              cap == 0
                  ? "This membership rolls no unused sessions."
                  : "Rolls up to $cap unused session${cap == 1 ? "" : "s"}, the same as the membership.",
              style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          BtnGold(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? "Saving…" : "Save"),
          ),
        ],
      ),
    );
  }
}
