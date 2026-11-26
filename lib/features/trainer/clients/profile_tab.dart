import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/widgets/city_state_fields.dart";
import "../../../core/widgets/password_actions.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/client_status_utils.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/flag_utils.dart";
import "../../../core/utils/membership_rollover.dart";
import "../../../core/utils/membership_utils.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/utils/program_utils.dart";
import "../../../core/utils/intake_resubmit.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/charge.dart";
import "../../../data/models/client_info.dart";
import "../../../data/models/intake_schema.dart";
import "../../../data/models/membership_plan.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "../../../data/providers/coach_permissions_provider.dart";
import "../../client/drawer_screens/payment_details_section.dart";
import "billing_anchor_section.dart";
import "plan_allowance_section.dart";
import "plan_expiry_row.dart";
import "plan_price_row.dart";
import "renewal_terms_section.dart";
import "../../shared/balance_card.dart";
import "charge_client_section.dart";
import "../../../core/privacy/client_contact_privacy.dart";
import "coach_private_fields.dart";
import "purchase_for_client_section.dart";
import "../../../core/utils/phone_guard.dart";
import "../../../data/models/client_plan.dart";
import "../../../core/utils/freeze_utils.dart";

/// Mirrors Profile.jsx (viewed from the coach side, via TrainerView). Trimmed
/// vs. the web: Edit Profile is a simplified name/email/phone/city form here
/// rather than the full IntakeForm. Everything else — price on the
/// membership line, real freeze/unfreeze (Stripe pause_collection via
/// freeze-membership/unfreeze-membership), the remaining-sessions editor
/// (available to any coach, not just the owner), and Add Charge — persists
/// to the real backend the same as the web.
class ProfileTab extends ConsumerStatefulWidget {
  const ProfileTab({
    super.key,
    required this.clientId,
    required this.onGoToIntake,
    this.onRequestProgram,
  });

  final String clientId;
  /// Opens the client's intake. The assessment key is the row that was
  /// tapped, so the form itself opens rather than the list it sits in.
  final void Function(String assessmentKey) onGoToIntake;

  /// Owner only. [kind] is "training" or "nutrition".
  final void Function(String kind)? onRequestProgram;

  @override
  ConsumerState<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<ProfileTab> {
  String? _emergencyPhone;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (ref.read(trainerAuthProvider) != "owner") return;
      final phone = await SupabaseService.loadEmergencyPhone(widget.clientId);
      if (mounted) setState(() => _emergencyPhone = phone);
    });
  }

  bool _editing = false;
  bool _charging = false;
  bool _cardCharge = false;
  bool _billingAnchor = false;
  bool _renewalTerms = false;
  bool _purchasing = false;
  bool _paymentDetails = false;
  bool _freezing = false;
  bool _freezeBusy = false;
  bool _cancelBusy = false;
  late final _freezeStart = TextEditingController(text: isoToday());
  final _freezeEnd = TextEditingController();
  final _freezeReason = TextEditingController();
  String? _freezeErr;

  @override
  void dispose() {
    _freezeStart.dispose();
    _freezeEnd.dispose();
    _freezeReason.dispose();
    super.dispose();
  }

  List<Widget> _programRefreshBanners(WidgetRef ref, Map<String, String> flags) {
    if (flags.isEmpty) return const [];
    final isOwner = ref.watch(trainerAuthProvider) == "owner";
    final kinds = flags.keys.toList()..sort();
    return [
      for (final kind in kinds)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  programRefreshLabel(kind, forOwner: isOwner),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                // O3: owner only. Coaches see the neutral line above and no
                // button; clients never see this banner.
                if (isOwner && widget.onRequestProgram != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    rebuildProgramHint(flags[kind]),
                    style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  BtnGold(
                    full: true,
                    onPressed: () => widget.onRequestProgram!(kind),
                    child: Text(rebuildProgramLabel(kind)),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context, [WidgetRef? _]) => _build(context, ref);

  Widget _build(BuildContext context, WidgetRef ref) {
    final roster = ref.watch(trainerRosterProvider);
    final matches = roster.where((c) => c.id == widget.clientId);
    if (matches.isEmpty) return const SizedBox.shrink();
    final info = matches.first;
    final records = ref.watch(trainerClientRecordsProvider);
    final record = records[widget.clientId];
    final bookings = ref
        .watch(allBookingsProvider)
        .where((b) => b.clientId == widget.clientId)
        .toList();
    final status = record != null
        ? computeClientStatus(record, bookings: bookings)
        : ClientStatus.newClient;
    final meta = kStatusMeta[status]!;
    final plan = ref
        .watch(membershipPlansProvider.notifier)
        .byId(info.membershipPlanId);
    final notes = record != null ? getClientProgramNotes(record) : const [];
    final earnedBadges = ref.watch(earnedBadgesProvider);
    final hasActiveBadges = earnedBadges.any(
      (b) => b.clientId == widget.clientId && b.isActive,
    );

    void update(ClientInfoUpdater updater) => ref
        .read(trainerRosterProvider.notifier)
        .update(widget.clientId, updater);

    if (_editing) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _editing = false),
        child: _EditSection(
          info: info,
          showContact: ref.watch(trainerAuthProvider) == "owner",
          onCancel: () => setState(() => _editing = false),
          onSave: (name, email, phone, city, state) async {
            final isOwner = ref.read(trainerAuthProvider) == "owner";
            await SupabaseService.updateClientRow(
              info.id,
              name: name,
              // A coach must not change or clear a client's email or phone.
              email: isOwner ? email : null,
              phone: isOwner ? phone : null,
              city: city,
              state: state,
            );
            update(
              (c) => c.copyWith(
                name: name,
                email: email,
                phone: phone,
                city: city,
                state: state,
              ),
            );
            if (mounted) setState(() => _editing = false);
          },
        ),
      );
    }

    if (_renewalTerms) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _renewalTerms = false),
        child: RenewalTermsSection(info: info, onBack: () => setState(() => _renewalTerms = false)),
      );
    }

    if (_billingAnchor) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _billingAnchor = false),
        child: BillingAnchorSection(
          info: info,
          onBack: () => setState(() => _billingAnchor = false),
          onChanged: (day) => update((c) => c.copyWith(billingAnchorDay: day)),
        ),
      );
    }

    if (_paymentDetails) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _paymentDetails = false),
        child: PaymentDetailsSection(
          clientId: info.id,
          clientName: info.name,
          viewer: ref.watch(trainerAuthProvider) == "owner" ? BillingViewer.owner : BillingViewer.coach,
          onBack: () => setState(() => _paymentDetails = false),
        ),
      );
    }

    if (_purchasing) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _purchasing = false),
        child: PurchaseForClientSection(
          info: info,
          onBack: () => setState(() => _purchasing = false),
          onPlanAssigned: (planId) => update((c) => c.copyWith(membershipPlanId: planId)),
        ),
      );
    }

    if (_cardCharge) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _cardCharge = false),
        child: ChargeClientSection(clientId: widget.clientId, onClose: () => setState(() => _cardCharge = false)),
      );
    }

    if (_charging) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _charging = false),
        child: _AddChargeForm(
          info: info,
          onCancel: () => setState(() => _charging = false),
          onSubmit: (category, description, amount) async {
            final saved = await SupabaseService.insertCharge(
              Charge(
                id: "",
                clientId: info.id,
                clientName: info.name,
                type: "manual",
                date: isoToday(),
                at: stamp(),
                category: category,
                description: description,
                amount: amount,
              ),
            );
            ref.read(chargesProvider.notifier).add(saved);
            if (mounted) setState(() => _charging = false);
          },
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(src: info.photo, name: info.name, size: 52, active: true),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 19,
                    ),
                  ),
                  Text(
                    "ONE Fitness client",
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._programRefreshBanners(ref, record?.programRefresh ?? const {}),
          const SectionLabel("Active Merit Badges"),
          hasActiveBadges
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: MeritBadgeRow(
                    clientId: widget.clientId,
                    earnedBadges: earnedBadges,
                  ),
                )
              : Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Text(
                    "No Merit Badges earned yet.",
                    style: TextStyle(fontSize: 12, color: AppColors.mute),
                  ),
                ),
          _IntakeStatusSummary(
            intake: record?.intake ?? const {},
            onTap: widget.onGoToIntake,
          ),
          if (record != null) FlagAlert(flag: getHighestFlag(record, info)),
          if (notes.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.08),
                border: Border.all(color: AppColors.danger),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Text("📝", style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Client left ${notes.length == 1 ? 'a note' : '${notes.length} notes'} on their workout program — review before session",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          AppCard(
            child: Row(
              children: [
                StatusDot(status: status, size: 14),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "PROGRESS STATUS",
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.mute,
                        letterSpacing: 1,
                      ),
                    ),
                    Text(
                      meta.label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      meta.desc,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.mute,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.creditCard,
                      size: 17,
                      color: AppColors.gold,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "MEMBERSHIP",
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.mute,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            plan != null
                                ? _membershipLabel(plan, info)
                                : "No membership selected",
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (info.membershipCancelsAt != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                "Cancelled · access ends ${niceDate(info.membershipCancelsAt!)}",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.errorText,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          if (info.bookingRestricted)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                "Restricted from booking${info.bookingRestrictedReason != null ? ' · ${info.bookingRestrictedReason}' : ''}",
                                style: TextStyle(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w700),
                              ),
                            ),
                          if (info.membershipPaused)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                "Frozen ${info.membershipPausedAt ?? ''}${info.membershipFreezeEndsAt != null ? ' – ${info.membershipFreezeEndsAt}' : ''}",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.warning,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          else if (freezeScheduled(info))
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                "Freeze scheduled ${info.membershipPausedAt}${info.membershipFreezeEndsAt != null ? ' – ${info.membershipFreezeEndsAt}' : ''}",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.warning,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          if ((plan == null ? null : heldSessionsLeft(info, plan, bookings)) case final held?)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                "Held from freeze: ${heldSessionsLine(held.left, held.until)}",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.gold,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (plan != null) ...[
                  const SizedBox(height: 12),
                  if (_freezeErr != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _freezeErr!,
                        style: TextStyle(
                          color: AppColors.errorText,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (info.membershipPaused || freezeScheduled(info))
                    BtnGold(
                      full: true,
                      onPressed: _freezeBusy
                          ? null
                          : () => ref.read(trainerAuthProvider) == "owner"
                              ? _unfreeze(info, update)
                              : _requestUnfreeze(info),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(LucideIcons.refreshCw, size: 14),
                          const SizedBox(width: 6),
                          Text(_freezeBusy
                              ? "Working…"
                              : (info.membershipPaused ? "Unfreeze now" : "Cancel scheduled freeze")),
                        ],
                      ),
                    )
                  else if (info.membershipCancelsAt != null)
                    // Already cancelled — nothing left to freeze or cancel.
                    // It runs out on its own on the date shown above.
                    const SizedBox.shrink()
                  else if (_freezing)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.bg,
                        border: Border.all(color: AppColors.line),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            freezeFormExplainer(info.name),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.mute,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: FieldLabeled(
                                  label: "Start (YYYY-MM-DD)",
                                  child: AppField(kind: FieldKind.date, controller: _freezeStart),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FieldLabeled(
                                  label: "End (YYYY-MM-DD)",
                                  child: AppField(kind: FieldKind.date, controller: _freezeEnd),
                                ),
                              ),
                            ],
                          ),
                          if (ref.watch(trainerAuthProvider) != "owner") ...[
                            const SizedBox(height: 10),
                            FieldLabeled(
                              label: "Reason",
                              child: AppField(controller: _freezeReason, placeholder: "Why they asked to freeze"),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "This goes to the owner. After they approve it, the freeze starts 48 hours later, or on the from-date if that is later.",
                              style: TextStyle(fontSize: 12, color: AppColors.mute),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              BtnGold(
                                onPressed: _freezeBusy
                                    ? null
                                    : () => _confirmFreeze(info, update),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(LucideIcons.snowflake, size: 14),
                                    const SizedBox(width: 6),
                                    Text(
                                      _freezeBusy
                                          ? "Freezing…"
                                          : "Confirm freeze",
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              BtnGhost(
                                onPressed: () => setState(() {
                                  _freezing = false;
                                  _freezeErr = null;
                                }),
                                child: const Text("Cancel"),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else
                    BtnGhost(
                      full: true,
                      onPressed: () => setState(() => _freezing = true),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.snowflake, size: 14),
                          SizedBox(width: 6),
                          Text("Freeze membership"),
                        ],
                      ),
                    ),
                  // Ending the membership outright, with an explicit choice
                  // about when access stops. Separate from freeze, and
                  // deliberately the last action in this block. Hidden once
                  // a cancellation is already in place.
                  if (info.membershipCancelsAt == null && ref.watch(coachCanProvider(CoachPermission.editPlans))) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: _cancelBusy ? null : () => _confirmCancelMembership(info, plan, update),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.errorText,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      icon: const Icon(LucideIcons.circleX, size: 14),
                      label: Text(
                        _cancelBusy ? "Cancelling…" : "Cancel membership",
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  ],
                ],
                if (plan != null && plan.kind != PlanKind.program && ref.watch(trainerAuthProvider) == "owner")
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: PlanPriceRow(
                      info: info,
                      plan: plan,
                      onChanged: (plans) => update((c) => c.copyWith(plans: plans)),
                    ),
                  ),
                if (plan != null && plan.kind != PlanKind.program && ref.watch(trainerAuthProvider) == "owner")
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: PlanExpiryRow(
                      info: info,
                      plan: plan,
                      onChanged: (plans) => update((c) => c.copyWith(plans: plans)),
                    ),
                  ),
                if (plan != null && plan.kind == PlanKind.package && ref.watch(coachCanProvider(CoachPermission.editPlans))) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.only(top: 12),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: AppColors.line)),
                      ),
                      child: _SessionOverrideRow(
                        info: info,
                        plan: plan,
                        bookings: bookings,
                        onSave: (total, month, clear) async {
                          final next = withPlanAllowance(
                            info.plans,
                            planId: plan.id,
                            today: isoToday(),
                            touchSessions: true,
                            clearSessions: clear,
                            maxSessionsOverride: total,
                            maxSessionsOverrideMonth: month,
                          );
                          await SupabaseService.updateClientPlans(info.id, next);
                          if (info.sessionCountOverride != null) {
                            await SupabaseService.updateClientRow(
                              info.id,
                              clearSessionCountOverride: true,
                            );
                          }
                          update((c) => c.copyWith(
                                plans: next,
                                clearSessionCountOverride: true,
                              ));
                        },
                      ),
                    ),
                  ),
                ],
                if (ref.watch(coachCanProvider(CoachPermission.editPlans)))
                  PlanAllowances(
                    info: info,
                    plans: ref.watch(membershipPlansProvider),
                    bookings: bookings,
                    onChanged: (next) => update((_) => next),
                  ),
              ],
            ),
          ),
          if (ref.watch(trainerAuthProvider) == "owner" &&
              plan != null &&
              plan.kind == PlanKind.membership) ...[
            AppCard(
              onTap: () => setState(() => _renewalTerms = true),
              child: Row(
                children: [
                  Icon(LucideIcons.refreshCw, size: 17, color: AppColors.gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("RENEWAL PRICE & DATES", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
                        const Text("See and change what it renews at, when, and when it ends", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: 15, color: AppColors.mute),
                ],
              ),
            ),
            AppCard(
              onTap: () => setState(() => _billingAnchor = true),
              child: Row(
                children: [
                  Icon(LucideIcons.calendarClock, size: 17, color: AppColors.gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("BILLING DATE", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
                        Text(
                          info.billingAnchorDay != null ? "Bills on the ${ordinalDay(info.billingAnchorDay!)} of the month" : "Bills on whatever day they signed up",
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: 15, color: AppColors.mute),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (ref.watch(trainerAuthProvider) == "owner")
            _ContactRow(
              icon: LucideIcons.mail,
              label: "Email",
              value: info.email,
            ),
          _ContactRow(
            icon: LucideIcons.cake,
            label: "Birthday",
            value: info.birthday != null
                ? "${_niceDate(info.birthday!)} (age ${_ageFrom(info.birthday!)})"
                : null,
          ),
          if (ref.watch(trainerAuthProvider) == "owner")
            _ContactRow(
              icon: LucideIcons.phone,
              label: "Phone",
              value: info.phone,
            ),
          _ContactRow(
            icon: LucideIcons.heartPulse,
            label: "Emergency contact",
            value: _emergencyLine(
              info,
              showPhone: ref.watch(trainerAuthProvider) == "owner",
              phone: _emergencyPhone,
            ),
          ),
          _ContactRow(
            icon: LucideIcons.mapPin,
            label: "City",
            value: info.city,
          ),
          // Same two options as the coach profile, in the same place and
          // with the same wording — someone dealing with a locked-out
          // client shouldn't have to learn a second screen.
          PasswordActions(
            profileId: info.id,
            email: info.email ?? "",
            name: info.name,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: BtnGhost(
                  onPressed: () => setState(() => _editing = true),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.edit3, size: 14),
                      SizedBox(width: 6),
                      Text("Edit profile"),
                    ],
                  ),
                ),
              ),
              if (ref.watch(trainerAuthProvider) == "owner") ...[
                const SizedBox(width: 8),
                Expanded(
                  child: BtnGhost(
                    onPressed: () => setState(() => _charging = true),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.creditCard, size: 14),
                        SizedBox(width: 6),
                        Text("Add charge"),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (ref.watch(coachCanProvider(CoachPermission.billingAccess)))
            BalanceCard(
              key: ValueKey("balance-${info.id}"),
              clientId: info.id,
              editable: ref.watch(trainerAuthProvider) == "owner",
              canPay: false,
            ),
          if (ref.watch(coachCanProvider(CoachPermission.chargeFees))) ...[
            BtnGold(
              key: const Key("profile-charge-card"),
              full: true,
              onPressed: () => setState(() => _cardCharge = true),
              child: const Text("Charge their card"),
            ),
            const SizedBox(height: 8),
          ],
          if (ref.watch(trainerAuthProvider) != "owner") ...[
            const SizedBox(height: 8),
            _CoachAskRow(
              busy: _freezeBusy,
              restricted: info.bookingRestricted,
              onRestrict: () => _ask(info, "restrict_client", "Restrict ${info.name}", "Why should booking be paused?"),
              onLift: () => _ask(info, "lift_restriction", "Lift the restriction", "Why should they be able to book again?"),
              onBalance: () => _askBalance(info),
              onDelete: () => _ask(info, "delete_client", "Ask to delete ${info.name}", "Why should this account be deleted?"),
            ),
          ],
          if (ref.watch(coachCanProvider(CoachPermission.editPlans))) ...[
            BtnGold(
              key: const Key("profile-purchase-for-client"),
              full: true,
              onPressed: () => setState(() => _purchasing = true),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.shoppingCart, size: 14),
                  SizedBox(width: 6),
                  Text("Purchase for client"),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (ref.watch(coachCanProvider(CoachPermission.billingAccess)))
            OutlinedButton.icon(
              key: const Key("profile-payment-details"),
              onPressed: () => setState(() => _paymentDetails = true),
              icon: const Icon(LucideIcons.creditCard, size: 14),
              label: const Text("Payment details (add or remove card)"),
            ),
          if (ref.watch(trainerAuthProvider) == "owner") ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _freezeBusy
                  ? null
                  : () async {
                      if (info.bookingRestricted) {
                        await SupabaseService.setClientRestriction(clientId: info.id, restricted: false);
                        update((c) => c.copyWith(bookingRestricted: false, clearBookingRestrictedReason: true));
                      } else {
                        await SupabaseService.setClientRestriction(
                          clientId: info.id,
                          restricted: true,
                          reason: "Set by the owner",
                        );
                        update((c) => c.copyWith(bookingRestricted: true, bookingRestrictedReason: "Set by the owner"));
                      }
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(info.bookingRestricted ? "Restriction lifted." : "Booking restricted.")),
                        );
                      }
                    },
              icon: const Icon(LucideIcons.shieldAlert, size: 14),
              label: Text(info.bookingRestricted ? "Lift booking restriction" : "Restrict booking"),
            ),
            const SizedBox(height: 18),
            Container(height: 1, color: AppColors.line),
            const SizedBox(height: 14),
            Center(
              child: TextButton(
                onPressed: () => _deleteClient(info),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.errorText,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.trash2, size: 14),
                  SizedBox(width: 6),
                  Text("Delete client"),
                ],
              ),
            ),
          ),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteClient(ClientInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Delete client?"),
        content: Text(
          "Delete ${info.name}? This permanently removes their profile, programs, logs, history, squad/challenge participation, and login — everywhere in the app, immediately. They can't be reactivated; to come back, they'd have to sign up again from scratch as a brand-new profile. This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      notifyPush(
        profileId: info.id,
        title: "Account deleted",
        body: "Your ONE Fitness profile has been deleted.",
        sms: true,
      );
      notifyAllCoaches(
        title: "Client deleted",
        body: "${info.name}'s profile was deleted.",
      );
      notifyOwnerInternal(title: "Profile deleted", body: "${info.name}'s profile was deleted.");
      await SupabaseService.deleteClientAccount(info.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst("Exception: ", "")),
          ),
        );
      }
      return;
    }
    ref.read(trainerRosterProvider.notifier).remove(info.id);
    ref.read(trainerClientRecordsProvider.notifier).remove(info.id);
    ref.read(selectedClientIdProvider.notifier).select(null);
    // Best-effort freshness for the two other places this client could
    // still be lingering in memory — the server-side cleanup already
    // stripped them out of squads/challenges, this just pulls that down so
    // the UI doesn't keep showing a ghost member/participant until the next
    // full reload.
    try {
      final freshSquads = await SupabaseService.loadSquads();
      ref.read(squadsProvider.notifier).setAll(freshSquads);
      final freshChallenges = await SupabaseService.loadChallenges();
      ref.read(challengesProvider.notifier).setAll(freshChallenges);
    } catch (_) {}
  }

  String _membershipLabel(MembershipPlan plan, ClientInfo info) {
    var cents = plan.priceCents;
    for (final e in info.plans) {
      if (e.planId == plan.id && e.status == "active" && e.priceCents != null) cents = e.priceCents!;
    }
    if (cents <= 0) return "${plan.name} — Free";
    final price = "\$${(cents / 100).toStringAsFixed(2)}";
    final suffix = plan.kind == PlanKind.membership ? "/mo" : "";
    return "${plan.name} — $price$suffix";
  }

  Future<void> _ask(ClientInfo info, String kind, String title, String prompt) async {
    final reason = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: TextField(
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          controller: reason,
          maxLines: 3,
          decoration: InputDecoration(hintText: prompt),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, reason.text.trim()), child: const Text("Send")),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => reason.dispose());
    if (text == null || !mounted) return;
    if (text.isEmpty && kind != "lift_restriction") {
      setState(() => _freezeErr = "Add a reason so the owner can decide.");
      return;
    }
    await _send(info, kind, text.isEmpty ? "Lift the booking restriction." : text, const {});
  }

  Future<void> _askBalance(ClientInfo info) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final saved = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Ask to change the balance", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(prefixText: "\$ ", labelText: "New balance (minus if they owe)"),
            ),
            const SizedBox(height: 8),
            TextField(
              onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              controller: note, decoration: const InputDecoration(labelText: "Reason")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(
            onPressed: () {
              final v = double.tryParse(amount.text.trim());
              if (v == null || note.text.trim().isEmpty) return;
              Navigator.pop(ctx, (v * 100).round());
            },
            child: const Text("Send"),
          ),
        ],
      ),
    );
    final why = note.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      amount.dispose();
      note.dispose();
    });
    if (saved == null || !mounted) return;
    await _send(info, "adjust_balance", why, {"cents": saved});
  }

  Future<void> _requestUnfreeze(ClientInfo info) =>
      _send(info, "unfreeze_membership", "End this freeze.", const {});

  Future<void> _send(ClientInfo info, String kind, String reason, Map<String, dynamic> payload) async {
    setState(() {
      _freezeBusy = true;
      _freezeErr = null;
    });
    try {
      await SupabaseService.submitCoachRequest(kind: kind, clientId: info.id, reason: reason, payload: payload);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Sent to the owner. Nothing changes until they approve it.")),
      );
      setState(() => _freezing = false);
    } catch (e) {
      if (mounted) setState(() => _freezeErr = e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _freezeBusy = false);
    }
  }

  Future<void> _unfreeze(
    ClientInfo info,
    void Function(ClientInfoUpdater) update,
  ) async {
    setState(() {
      _freezeBusy = true;
      _freezeErr = null;
    });
    try {
      final res = await SupabaseService.unfreezeMembership(info.id);
      final plans = res["plans"] is List ? SupabaseService.enrollmentsFromJson(res["plans"]) : null;
      update(
        (c) => c.copyWith(
          membershipPaused: false,
          clearMembershipPausedAt: true,
          clearMembershipFreezeEndsAt: true,
          plans: plans,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(unfreezeResultMessage(res, plans ?? info.plans))),
        );
      }
    } catch (e) {
      if (mounted)
        setState(
          () => _freezeErr = e.toString().replaceFirst("Exception: ", ""),
        );
    } finally {
      if (mounted) setState(() => _freezeBusy = false);
    }
  }


  /// Staff ending a client's membership. The choice that matters is when
  /// access actually stops, so it's the whole dialog rather than a footnote:
  /// letting them finish the period they've paid for is the default, and
  /// cancelling outright is the deliberate second option.
  Future<void> _confirmCancelMembership(
    ClientInfo info,
    MembershipPlan plan,
    void Function(ClientInfoUpdater) update,
  ) async {
    setState(() {
      _cancelBusy = true;
      _freezeErr = null;
    });

    Map<String, dynamic> preview;
    try {
      preview = await SupabaseService.adminCancelMembershipPreview(info.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cancelBusy = false;
        _freezeErr = "Couldn't check this membership — check your connection and try again.";
      });
      return;
    }
    if (!mounted) return;
    setState(() => _cancelBusy = false);

    final endsAt = preview["periodEndsAt"] as String?;
    final canScheduleEnd = preview["canScheduleEnd"] == true;

    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text("Cancel ${plan.name}?",
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "How should ${info.name}'s access end?",
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),
            _CancelModeOption(
              title: "Let them finish",
              detail: canScheduleEnd
                  ? "Billing stops now. They keep their sessions until ${endsAt ?? 'the end of the period'}, which they've already paid for."
                  : "Not available — this plan has no billing period to run out.",
              enabled: canScheduleEnd,
              onTap: () => Navigator.of(ctx).pop("period_end"),
            ),
            const SizedBox(height: 8),
            _CancelModeOption(
              title: "Cancel immediately",
              detail: "Access ends right now and the membership is removed. Use this for a refund or a member who has left.",
              enabled: true,
              danger: true,
              onTap: () => Navigator.of(ctx).pop("immediate"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: TextButton.styleFrom(foregroundColor: AppColors.mute),
            child: const Text("Keep membership"),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    setState(() => _cancelBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await SupabaseService.adminCancelMembership(clientId: info.id, mode: mode);
      if (!mounted) return;
      setState(() => _cancelBusy = false);
      final cancelsAt = res["cancelsAt"] as String?;
      messenger.showSnackBar(SnackBar(
        content: Text(cancelsAt != null
            ? "Membership ends ${cancelsAt}. Billing has stopped."
            : "Membership cancelled. Access has ended."),
        duration: const Duration(seconds: 5),
      ));
      // Mirror what the server just did so the card updates now.
      if (cancelsAt != null) {
        update((c) => c.copyWith(membershipCancelsAt: cancelsAt));
      } else {
        update((c) => c.copyWith(
              clearMembershipPlanId: true,
              clearStripeSubscriptionId: true,
              clearMembershipCancelsAt: true,
            ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cancelBusy = false;
        _freezeErr = e.toString().replaceFirst("Exception: ", "");
      });
    }
  }

  Future<void> _confirmFreeze(
    ClientInfo info,
    void Function(ClientInfoUpdater) update,
  ) async {
    if (_freezeEnd.text.trim().isEmpty) {
      setState(() => _freezeErr = "An end date is required.");
      return;
    }
    setState(() {
      _freezeBusy = true;
      _freezeErr = null;
    });
    final start = _freezeStart.text.trim().isEmpty
        ? isoToday()
        : _freezeStart.text.trim();
    final end = _freezeEnd.text.trim();
    final isOwner = ref.read(trainerAuthProvider) == "owner";
    if (!isOwner && _freezeReason.text.trim().isEmpty) {
      setState(() {
        _freezeBusy = false;
        _freezeErr = "Add a reason so the owner can decide.";
      });
      return;
    }
    try {
      if (!isOwner) {
        await SupabaseService.submitCoachRequest(
          kind: "freeze_membership",
          clientId: info.id,
          reason: _freezeReason.text.trim(),
          payload: {"from": start, "to": end},
        );
        if (!mounted) return;
        setState(() => _freezing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Freeze sent to the owner. It starts 48 hours after they approve it.")),
        );
        return;
      }
      final res = await SupabaseService.freezeMembership(info.id, start, end);
      final scheduled = res["scheduled"] == true;
      final plans = res["plans"] is List ? SupabaseService.enrollmentsFromJson(res["plans"]) : null;
      update(
        (c) => c.copyWith(
          membershipPaused: !scheduled,
          membershipPausedAt: start,
          membershipFreezeEndsAt: end,
          plans: plans,
        ),
      );
      if (scheduled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Freeze scheduled. It starts $start. Booking stays open until then.")),
        );
      }
      if (mounted) setState(() => _freezing = false);
    } catch (e) {
      if (mounted)
        setState(
          () => _freezeErr = e.toString().replaceFirst("Exception: ", ""),
        );
    } finally {
      if (mounted) setState(() => _freezeBusy = false);
    }
  }
}

typedef ClientInfoUpdater = ClientInfo Function(ClientInfo);

const _kIntakeStatusItems = [
  ("personalTraining", "Personalized Training Intake"),
  ("nutritional", "Nutrition Program Intake"),
  ("physical", "Free Physical Assessment Session"),
];

/// Mirrors OnboardingAlerts.jsx `IntakeStatusSummary` — always all 3 forms,
/// in this fixed order, whether complete or not (unlike the client
/// dashboard's onboarding banner, which drops each step off the list once
/// done). Tapping any row opens the full Intake list (IntakeTab).
class _IntakeStatusSummary extends StatelessWidget {
  const _IntakeStatusSummary({required this.intake, required this.onTap});

  final Map<String, IntakeRecord> intake;
  final void Function(String assessmentKey) onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: _kIntakeStatusItems.map((item) {
          final (key, label) = item;
          final rec = intake[key];
          final done = rec?.completed ?? false;
          return Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: TapHighlight(
              onTap: () => onTap(key),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: done
                      ? AppColors.gold.withValues(alpha: 0.06)
                      : AppColors.card,
                  border: Border.all(
                    color: done ? AppColors.goldDim : AppColors.line,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    done
                        ? Icon(
                            LucideIcons.check,
                            size: 16,
                            color: AppColors.gold,
                          )
                        : Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.danger,
                            ),
                          ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              done
                                  ? "Completed by ${rec?.by ?? "Client"}${rec?.at != null ? " · ${rec!.at}" : ""}"
                                  : "Not completed yet",
                              style: TextStyle(
                                fontSize: 11,
                                color: done ? AppColors.gold : AppColors.mute,
                              ),
                            ),
                          ),
                          // Says the earlier answers are still there before a
                          // coach opens it — otherwise a re-intake looks like
                          // it simply replaced whatever was on file.
                          if ((rec?.history.length ?? 0) > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                rec!.history.length == 1
                                    ? "1 earlier submission kept"
                                    : "${rec.history.length} earlier submissions kept",
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: AppColors.mute,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      LucideIcons.chevronRight,
                      size: 15,
                      color: AppColors.mute,
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

String? _emergencyLine(ClientInfo info, {required bool showPhone, String? phone}) {
  final parts = [
    if ((info.emergencyContactName ?? "").trim().isNotEmpty) info.emergencyContactName!.trim(),
    if (showPhone && (phone ?? "").trim().isNotEmpty) phone!.trim(),
  ];
  if (parts.isEmpty) return null;
  return parts.join(" · ");
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          Icon(icon, size: 17, color: AppColors.gold),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.mute,
                  letterSpacing: 1,
                ),
              ),
              Text(
                value ?? "—",
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Remaining sessions for this package only. The coach types how many are
/// left; that's stored on this package's plan entry, so it cannot follow
/// the client onto a membership or another package.
class _SessionOverrideRow extends StatefulWidget {
  const _SessionOverrideRow({
    required this.info,
    required this.plan,
    required this.bookings,
    required this.onSave,
  });
  final ClientInfo info;
  final MembershipPlan plan;
  final List<Booking> bookings;

  /// (total, month, clear) — clear:true means "remove the override entirely".
  final Future<void> Function(int? total, String? month, bool clear) onSave;

  @override
  State<_SessionOverrideRow> createState() => _SessionOverrideRowState();
}

class _SessionOverrideRowState extends State<_SessionOverrideRow> {
  late final TextEditingController _draft;
  bool _busy = false;

  int get _used =>
      sessionsUsedThisPeriod(widget.info, widget.plan, widget.bookings);
  int get _defaultRemaining =>
      ((widget.plan.maxSessions ?? 0) - _used).clamp(0, 1 << 30);
  bool get _hasOverride =>
      sessionOverrideIsSet(widget.info, widget.plan, isoToday().substring(0, 7));
  int? get _currentRemaining => _hasOverride
      ? (effectiveMaxSessions(widget.info, widget.plan) - _used).clamp(
          0,
          1 << 30,
        )
      : null;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(
      text: _currentRemaining != null ? "$_currentRemaining" : "",
    );
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final trimmed = _draft.text.trim();
    setState(() => _busy = true);
    try {
      if (trimmed.isEmpty) {
        await widget.onSave(null, null, true);
      } else {
        final desiredRemaining = int.tryParse(trimmed)?.clamp(0, 1 << 30) ?? 0;
        final month = widget.plan.kind == PlanKind.membership
            ? isoToday().substring(0, 7)
            : null;
        await widget.onSave(_used + desiredRemaining, month, false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentRemaining = _currentRemaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "REMAINING SESSIONS",
          style: TextStyle(
            fontSize: 10,
            color: AppColors.mute,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(
              width: 90,
              child: AppField(
                controller: _draft,
                placeholder: "$_defaultRemaining",
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            BtnGhost(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? "Saving…" : "Save"),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            (currentRemaining != null
                    ? "Currently set to $currentRemaining remaining — the plan default right now would be $_defaultRemaining."
                    : "Using the plan's default of $_defaultRemaining remaining. Leave blank to clear an override.") +
                " This number is only for ${widget.plan.name}. It does not carry to another plan." +
                " It drops when a client checks in or is a no-show, not when they book. Cancelling gives the session back right away.",
            style: TextStyle(fontSize: 11, color: AppColors.mute),
          ),
        ),
      ],
    );
  }
}

const _kChargeCategories = [
  ("membership", "Membership"),
  ("package", "Session Package"),
  ("assessment", "Assessment"),
  ("recovery", "Recovery"),
  ("merchandise", "Merchandise"),
  ("supplements", "Supplements"),
  ("fee", "Fee"),
  ("other", "Other"),
];

/// Mirrors AddChargeForm.jsx — logs a one-off manual charge against this
/// client (e.g. a no-show fee, merchandise sale) for the owner/coach to
/// collect; purely a ledger entry, no real Stripe payment is taken here.
class _AddChargeForm extends StatefulWidget {
  const _AddChargeForm({
    required this.info,
    required this.onCancel,
    required this.onSubmit,
  });
  final ClientInfo info;
  final VoidCallback onCancel;
  final Future<void> Function(
    String category,
    String description,
    double amount,
  )
  onSubmit;

  @override
  State<_AddChargeForm> createState() => _AddChargeFormState();
}

class _AddChargeFormState extends State<_AddChargeForm> {
  String _category = "fee";
  final _description = TextEditingController();
  final _amount = TextEditingController();
  String? _err;
  bool _busy = false;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_description.text.trim().isEmpty) {
      setState(() => _err = "Add a description.");
      return;
    }
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _err = "Enter a valid amount.");
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.onSubmit(_category, _description.text.trim(), amount);
    } catch (e) {
      if (mounted)
        setState(() => _err = e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: widget.onCancel, title: "Profile"),
          const SizedBox(height: 10),
          SectionLabel("Add Charge — ${widget.info.name}"),
          const SizedBox(height: 14),
          Text(
            "CATEGORY",
            style: TextStyle(
              fontSize: 10,
              color: AppColors.mute,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _kChargeCategories.map((c) {
              final (key, label) = c;
              final selected = _category == key;
              return TapHighlight(
                onTap: () => setState(() => _category = key),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? AppColors.gold : AppColors.line,
                    ),
                    color: selected
                        ? AppColors.gold
                        : AppColors.card,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.onGold : AppColors.mute,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          FieldLabeled(
            label: "Description *",
            child: AppField(
              controller: _description,
              placeholder: "e.g. Monthly membership, No-show fee…",
            ),
          ),
          const SizedBox(height: 10),
          FieldLabeled(
            label: "Amount (\$) *",
            child: AppField(
              controller: _amount,
              placeholder: "0.00",
              kind: FieldKind.decimal,
            ),
          ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _err!,
                style: TextStyle(color: AppColors.errorText, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          BtnGold(
            full: true,
            onPressed: _busy ? null : _submit,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.creditCard, size: 14),
                const SizedBox(width: 6),
                Text(_busy ? "Adding…" : "Add charge"),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Mirrors lib/format.js `niceDate`.
String _niceDate(String iso) {
  final d = DateTime.parse(iso);
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return "${weekdays[d.weekday % 7]}, ${months[d.month - 1]} ${d.day}";
}

/// Mirrors lib/helpers.js `ageFrom`.
int _ageFrom(String iso) {
  final d = DateTime.parse(iso);
  final t = DateTime.now();
  var age = t.year - d.year;
  if (t.month < d.month || (t.month == d.month && t.day < d.day)) age--;
  return age;
}

class _EditSection extends StatefulWidget {
  const _EditSection({
    required this.info,
    required this.onCancel,
    required this.onSave,
    this.showContact = true,
  });
  final ClientInfo info;
  final bool showContact;
  final VoidCallback onCancel;
  final Future<void> Function(
    String name,
    String email,
    String phone,
    String city,
    String state,
  )
  onSave;

  @override
  State<_EditSection> createState() => _EditSectionState();
}

class _EditSectionState extends State<_EditSection> {
  late final _name = TextEditingController(text: widget.info.name);
  late final _email = TextEditingController(text: widget.info.email ?? "");
  late final _phone = TextEditingController(text: widget.info.phone ?? "");
  late final _city = TextEditingController(text: widget.info.city ?? "");
  late final _state = TextEditingController(text: widget.info.state ?? "");
  String? _err;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _city.dispose();
    _state.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final gymErr = widget.showContact ? gymNumberError(context, _phone.text.trim()) : null;
    if (gymErr != null) {
      setState(() => _err = gymErr);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.onSave(
        _name.text.trim(),
        _email.text.trim(),
        _phone.text.trim(),
        _city.text.trim(),
        _state.text.trim(),
      );
    } catch (e) {
      if (mounted)
        setState(() => _err = e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: widget.onCancel, title: "Profile"),
          const SizedBox(height: 10),
          const SectionLabel("Edit Profile"),
          FieldLabeled(
            label: "Name",
            child: AppField(kind: FieldKind.name, controller: _name),
          ),
          const SizedBox(height: 10),
          if (widget.showContact) ...[
            FieldLabeled(
              label: "Email",
              child: AppField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
              ),
            ),
            const SizedBox(height: 10),
            FieldLabeled(
              label: "Phone",
              child: AppField(
                controller: _phone,
                keyboardType: TextInputType.phone,
              ),
            ),
            const SizedBox(height: 10),
          ],
          CityStateFields(city: _city, state: _state, helper: null),
          if (widget.showContact) ...[
            const SizedBox(height: 14),
            OwnerBillingAddress(clientId: widget.info.id, clientName: widget.info.name),
          ],
          if (!widget.showContact) ...[
            const SizedBox(height: 14),
            CoachPrivatePhone(clientId: widget.info.id),
            const SizedBox(height: 10),
            Consumer(
              builder: (context, ref, _) => ref.watch(coachCanProvider(CoachPermission.billingAccess))
                  ? CoachPrivateAddress(clientId: widget.info.id, clientName: widget.info.name)
                  : const SizedBox.shrink(),
            ),
          ],
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _err!,
                style: TextStyle(color: AppColors.errorText, fontSize: 12),
              ),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: BtnGold(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? "Saving…" : "Save"),
                ),
              ),
              const SizedBox(width: 8),
              BtnGhost(onPressed: widget.onCancel, child: const Text("Cancel")),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of the two ways a staff member can end a membership. A card rather
/// than a radio row: the difference between them matters to the client, so
/// the consequence is spelled out under each rather than hidden behind a
/// label.
class _CancelModeOption extends StatelessWidget {
  const _CancelModeOption({
    required this.title,
    required this.detail,
    required this.enabled,
    required this.onTap,
    this.danger = false,
  });

  final String title;
  final String detail;
  final bool enabled;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? AppColors.errorText : AppColors.gold;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: TapHighlight(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: enabled ? accent : AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w800, color: enabled ? accent : AppColors.mute)),
              const SizedBox(height: 3),
              Text(detail,
                  style: TextStyle(fontSize: 11.5, color: AppColors.mute, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Coach actions that used to happen immediately and now wait for the owner.
class _CoachAskRow extends StatelessWidget {
  const _CoachAskRow({
    required this.busy,
    required this.restricted,
    required this.onRestrict,
    required this.onLift,
    required this.onBalance,
    required this.onDelete,
  });

  final bool busy;
  final bool restricted;
  final VoidCallback onRestrict;
  final VoidCallback onLift;
  final VoidCallback onBalance;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("ASK THE OWNER", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
        const SizedBox(height: 6),
        Text(
          "These wait in Requests until the owner approves them.",
          style: TextStyle(fontSize: 12, color: AppColors.mute),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!restricted)
              OutlinedButton(onPressed: busy ? null : onRestrict, child: const Text("Restrict booking"))
            else
              OutlinedButton(onPressed: busy ? null : onLift, child: const Text("Ask to lift restriction")),
            OutlinedButton(onPressed: busy ? null : onBalance, child: const Text("Ask to change balance")),
            OutlinedButton(onPressed: busy ? null : onDelete, child: const Text("Ask to delete")),
          ],
        ),
      ],
    );
  }
}

/// The note after the owner unfreezes: how many held sessions are left and
/// until when, or that a scheduled freeze was cancelled.
String unfreezeResultMessage(Map<String, dynamic> res, List<ClientPlanEnrollment> plans) {
  if (res["cancelledScheduled"] == true) return "Scheduled freeze cancelled.";
  final held = heldSessionsLineFromPlans(plans);
  return held == null ? "Unfrozen." : "Unfrozen. $held.";
}

/// What the freeze form tells staff before they confirm. The billing date
/// does not move: any charge that falls inside the freeze is skipped, and
/// billing picks up again on the client's normal billing date.
String freezeFormExplainer(String clientName) =>
    "Both dates are required. The end date is the first day $clientName can book again. "
    "While frozen they can't book and aren't charged — any billing date inside the freeze is skipped. "
    "Their billing date stays the same, so billing resumes on the next normal billing date after the freeze. "
    "Sessions they hadn't used yet are kept for after the freeze, until that billing date.";
