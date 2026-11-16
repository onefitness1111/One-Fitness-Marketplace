import "package:flutter/material.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../data/models/client_info.dart";
import "../../../data/models/client_plan.dart";
import "../../../data/models/membership_plan.dart";

/// Owner-only: when this client's access to [plan] runs out. Works for
/// packages and memberships alike — it edits the `endsAt` on the client's
/// enrolment, which is what the booking rules already check.
class PlanExpiryRow extends StatefulWidget {
  const PlanExpiryRow({super.key, required this.info, required this.plan, required this.onChanged});
  final ClientInfo info;
  final MembershipPlan plan;

  /// Receives the full updated enrolment list after a successful save.
  final void Function(List<ClientPlanEnrollment> plans) onChanged;

  @override
  State<PlanExpiryRow> createState() => _PlanExpiryRowState();
}

class _PlanExpiryRowState extends State<PlanExpiryRow> {
  bool _busy = false;

  ClientPlanEnrollment? get _enrolment {
    for (final e in widget.info.plans) {
      if (e.planId == widget.plan.id && e.status == "active") return e;
    }
    return null;
  }

  Future<void> _save(String? endsAt) async {
    setState(() => _busy = true);
    try {
      final existing = _enrolment;
      final List<ClientPlanEnrollment> next;
      if (existing != null) {
        next = [
          for (final e in widget.info.plans)
            if (identical(e, existing)) e.copyWith(endsAt: endsAt, clearEndsAt: endsAt == null) else e,
        ];
      } else {
        next = [
          ...widget.info.plans,
          ClientPlanEnrollment(
            planId: widget.plan.id,
            status: "active",
            startDate: isoToday(),
            termMonths: widget.plan.termMonths,
            endsAt: endsAt,
          ),
        ];
      }
      await SupabaseService.updateClientPlans(widget.info.id, next);
      widget.onChanged(next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(endsAt == null ? "Expiration removed." : "Access now expires on $endsAt.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save the expiration date — try again.")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final current = DateTime.tryParse(_enrolment?.endsAt ?? "");
    final d = await showDatePicker(
      context: context,
      initialDate: current ?? now.add(const Duration(days: 30)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (d == null) return;
    await _save("${d.year.toString().padLeft(4, "0")}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}");
  }

  @override
  Widget build(BuildContext context) {
    final ends = _enrolment?.endsAt;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("ACCESS EXPIRES", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
              const SizedBox(height: 2),
              Text(ends ?? "No expiration", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (ends != null)
          TextButton(onPressed: _busy ? null : () => _save(null), child: const Text("Remove")),
        TextButton(onPressed: _busy ? null : _pick, child: Text(ends == null ? "Set date" : "Change")),
      ],
    );
  }
}
