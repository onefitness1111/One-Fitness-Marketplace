import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/supabase/supabase_service.dart";
import "balance_booking_warning.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_limits.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/utils/membership_utils.dart";
import "../../../core/utils/scheduling_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/client_info.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/platform_settings_provider.dart";
import "../../../data/providers/trainer_providers.dart";
import "../shell/trainer_shell_state.dart";
import "client_search_picker.dart";
import "single_session_staff.dart";
import "coach_search_picker.dart";
import "override_prompt.dart";


/// Mirrors AddManualBookingModal.jsx — the coach/owner "book anything" tool.
/// Bypasses client-facing availability/membership gating on purpose, but
/// still enforces the trainer double-booking and capacity checks; the
/// owner may push past those with a confirmation, a coach cannot.
Future<void> showAddManualBookingSheet(
  BuildContext context,
  WidgetRef ref, {
  required String initialDate,
  // Set when opened from an existing or created session on the day view,
  // so the coach/time/type arrive filled in and only the client is chosen.
  String? initialTrainerId,
  int? initialSlot,
  int? initialDurationMin,
  String? initialSessionType,
  String? initialDiscipline,
  String? initialClientId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _AddManualBookingBody(initialDate: initialDate, initialTrainerId: initialTrainerId, initialSlot: initialSlot, initialDurationMin: initialDurationMin, initialSessionType: initialSessionType, initialDiscipline: initialDiscipline, initialClientId: initialClientId),
    ),
  );
}

class _AddManualBookingBody extends ConsumerStatefulWidget {
  const _AddManualBookingBody({
    required this.initialDate,
    this.initialTrainerId,
    this.initialSlot,
    this.initialDurationMin,
    this.initialSessionType,
    this.initialDiscipline,
    this.initialClientId,
  });
  final String initialDate;
  final String? initialTrainerId;
  final int? initialSlot;
  final int? initialDurationMin;
  final String? initialSessionType;
  final String? initialDiscipline;
  final String? initialClientId;

  @override
  ConsumerState<_AddManualBookingBody> createState() => _AddManualBookingBodyState();
}

class _AddManualBookingBodyState extends ConsumerState<_AddManualBookingBody> {
  ClientInfo? _client;
  bool _picking = true;

  @override
  void initState() {
    super.initState();
    final id = widget.initialClientId;
    if (id == null) return;
    final matches = ref.read(trainerRosterProvider).where((c) => c.id == id);
    if (matches.isEmpty) return;
    _client = matches.first;
    _picking = false;
  }
  bool _pickingCoach = false;
  late String? _trainerId = widget.initialTrainerId;
  late String _sessionType = widget.initialSessionType ?? "semi-private";
  late String _discipline = widget.initialDiscipline ?? "personal-training";
  late int _start = widget.initialSlot ?? 9 * 60;

  /// Null means one hour — the default for every session, and what the
  /// end-time field shows as a hint until an end is picked.
  late int? _end = widget.initialDurationMin != null && widget.initialSlot != null ? widget.initialSlot! + widget.initialDurationMin! : null;
  int get _durationMin => (_end ?? _start + 60) - _start;

  // A session can never be booked into the past — clamp whatever initial
  // date came in (e.g. a previously-tapped past calendar day) up to today,
  // same as the client-facing flow's own "never book the past" rule.
  late DateTime _date = () {
    final parsed = DateTime.tryParse(widget.initialDate) ?? DateTime.now();
    final today = DateTime.now();
    final todayMidnight = DateTime(today.year, today.month, today.day);
    final parsedMidnight = DateTime(parsed.year, parsed.month, parsed.day);
    return parsedMidnight.isBefore(todayMidnight) ? todayMidnight : parsedMidnight;
  }();
  String? _error;
  bool _saving = false;

  String _rosterName(String clientId) {
    final matches = ref
        .read(trainerRosterProvider)
        .where((c) => c.id == clientId);
    return matches.isEmpty ? "another client" : matches.first.name;
  }

  String _coachTitle(String trainerId) {
    final matches = ref.read(trainersProvider).where((t) => t.id == trainerId);
    if (matches.isEmpty) return "This coach";
    return matches.first.displayTitle;
  }

  Future<void> _book() async {
    final slot = _start;
    final trainerId = _trainerId;
    if (trainerId == null) {
      setState(() => _error = "Coach, date, and time are all required.");
      return;
    }
    if (_durationMin <= 0) {
      setState(() => _error = "End time must be after the start time.");
      return;
    }
    final dateIso = isoDate(_date);
    if (dateIso.compareTo(isoToday()) < 0) {
      setState(() => _error = "You can't book a session in the past.");
      return;
    }

    final isOwner = ref.read(trainerAuthProvider) == "owner";
    final bookings = ref.read(allBookingsProvider);
    final isAssessment = _sessionType.startsWith("assessment");
    final effectiveDiscipline = isAssessment ? "assessment" : _discipline;
    final coachName = _coachTitle(trainerId);

    final conflict = findTrainerConflict(
      bookings,
      trainerId,
      dateIso,
      slot,
      _sessionType,
      effectiveDiscipline,
    );
    String? overrideReason;
    if (conflict != null) {
      if (!isOwner) {
        setState(() => _error = coachOverlapRefusal);
        return;
      }
      final message = ownerOverlapOverrideMessage(
        coachName: coachName,
        conflictSlot: conflict.slot,
        clientName: _rosterName(conflict.clientId),
      );
      final ok = await confirmOwnerOverride(
        context,
        title: "Scheduling conflict",
        message: message,
      );
      if (!mounted || !ok) return;
      overrideReason = overrideReasonFor(
        BookingLimitKind.overlap,
        detail: overrideDetail(message),
      );
    }
    final cap = capacityInfo(bookings, trainerId, dateIso, slot, _sessionType);
    if (cap.atCap && conflict == null) {
      if (!isOwner) {
        setState(
          () => _error =
              "That session is already at capacity (${cap.cap}) — contact the owner to override.",
        );
        return;
      }
      final message = ownerCapacityOverrideMessage(
        clientName: _client!.name,
        count: cap.count,
        cap: cap.cap,
      );
      final ok = await confirmOwnerOverride(
        context,
        title: "Session at capacity",
        message: message,
      );
      if (!mounted || !ok) return;
      overrideReason = overrideReasonFor(
        BookingLimitKind.capacity,
        detail: overrideDetail(message),
      );
    }
    if (!await confirmStaffBalanceAdd(
          context,
          clientId: _client!.id,
          isOwner: isOwner,
        ) ||
        !mounted)
      return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final planForClient = isAssessment
        ? null
        : planToChargeFor(
            _client!,
            _sessionType,
            bookings,
            ref.read(membershipPlansProvider),
          );

    Future<void> insert(String? reason) async {
      var draft = Booking(
        id: "",
        clientId: _client!.id,
        trainerId: trainerId,
        date: dateIso,
        slot: slot,
        sessionType: _sessionType,
        discipline: effectiveDiscipline,
        isPhysicalAssessment: isAssessment,
        durationMin: _durationMin,
        // Charged to the client's own plan, same as a self-booking. An
        // assessment never costs a session, so it's left unattributed.
        planId: planForClient,
      );
      if (reason != null) draft = draft.withOwnerOverride(reason);
      final saved = await SupabaseService.insertBooking(draft);
      ref.read(allBookingsProvider.notifier).addBooking(saved);
      if (!mounted) return;
      Navigator.of(context).pop();
    }

    // No plan covers this: charge a single session or book it free (the
    // client needs a card on file either way). An override skips that and
    // inserts with the stamp, which is what the trigger accepts.
    if (!isAssessment &&
        planForClient == null &&
        !_client!.isStaff &&
        overrideReason == null) {
      final out = await bookClientWithoutPlan(
        context: context,
        clientName: _client!.name,
        clientId: _client!.id,
        sessionType: _sessionType,
        trainerId: trainerId,
        date: dateIso,
        slot: slot,
        discipline: effectiveDiscipline,
        priceCents: ref
            .read(platformSettingsProvider)
            .singleSessionPriceFor(_sessionType),
        isOwner: isOwner,
      );
      if (out == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      if (out.status == "requested") {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(out.message!)));
        Navigator.of(context).pop();
        return;
      }
      if (!out.booked) {
        final fresh = findTrainerConflict(
          ref.read(allBookingsProvider),
          trainerId,
          dateIso,
          slot,
          _sessionType,
          effectiveDiscipline,
        );
        if (!mounted) return;
        final retry = await offerBookingOverride(
          context,
          error: out.message ?? "",
          isOwner: isOwner,
          alreadyOverriding: false,
          unspecifiedFull:
              out.full && classifyBookingLimitError(out.message ?? "") == null,
          coachName: coachName,
          addingClientName: _client!.name,
          conflictSlot: fresh?.slot,
          conflictingClientName: fresh == null
              ? null
              : _rosterName(fresh.clientId),
          capacityCount: cap.atCap ? cap.count : null,
          capacityCap: cap.atCap ? cap.cap : null,
          refunded: out.refunded,
        );
        if (!mounted) return;
        if (retry.go) {
          overrideReason = retry.reason;
        } else {
          setState(() => _saving = false);
          if (retry.declined) {
            if (out.full && out.refunded) {
              await showFilledRefundDialog(
                context,
                singleSessionFailureMessage(out),
              );
            }
            return;
          }
          if (out.full && out.refunded && context.mounted) {
            await showFilledRefundDialog(
              context,
              singleSessionFailureMessage(out),
            );
          } else if (mounted) {
            setState(() => _error = singleSessionFailureMessage(out));
          }
          return;
        }
      } else {
        final made = await SupabaseService.loadBookingById(out.bookingId!);
        if (made != null) {
          ref.read(allBookingsProvider.notifier).addBooking(made);
        }
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      }
    }

    try {
      await insert(overrideReason);
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      if (isUnpaidBalanceError(e)) {
        setState(() {
          _saving = false;
          _error = staffBalanceWarningFromError(text);
        });
        return;
      }
      final fresh = findTrainerConflict(
        ref.read(allBookingsProvider),
        trainerId,
        dateIso,
        slot,
        _sessionType,
        effectiveDiscipline,
      );
      setState(() => _saving = false);
      final retry = await offerBookingOverride(
        context,
        error: e,
        isOwner: isOwner,
        alreadyOverriding: overrideReason != null,
        coachName: coachName,
        addingClientName: _client!.name,
        conflictSlot: classifyBookingLimitError(e) == BookingLimitKind.overlap
            ? fresh?.slot
            : null,
        conflictingClientName: fresh == null
            ? null
            : _rosterName(fresh.clientId),
        capacityCount: capacityPairFromError(e)?.$1,
        capacityCap: capacityPairFromError(e)?.$2,
      );
      if (!mounted || retry.declined) return;
      if (!retry.go) {
        setState(() => _error = staffBookingFailureMessage(e));
        return;
      }
      setState(() {
        _saving = true;
        _error = null;
      });
      try {
        await insert(retry.reason);
      } catch (e2) {
        if (!mounted) return;
        final again = e2.toString();
        setState(() {
          _saving = false;
          _error = isUnpaidBalanceError(e2)
              ? staffBalanceWarningFromError(again)
              : staffBookingFailureMessage(e2);
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(firstDate) ? firstDate : _date,
      firstDate: firstDate,
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final roster = ref.watch(trainerRosterProvider);
    final trainers = ref.watch(trainersProvider);
    final trainerAuth = ref.watch(trainerAuthProvider);
    final isOwner = trainerAuth == "owner";
    _trainerId ??= isOwner ? (trainers.isNotEmpty ? trainers.first.id : null) : trainerAuth;
    final isAssessment = _sessionType.startsWith("assessment");

    if (_picking) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel("Book a Session"),
            ClientSearchPicker(roster: roster, onSelect: (c) => setState(() {
                  _client = c;
                  _picking = false;
                })),
          ],
        ),
      );
    }

    // Customize Platform → Services narrows the menu. Assessments are staff
    // tools rather than a sold service, so they're never hidden.
    final settings = ref.watch(platformSettingsProvider);
    final types = [...settings.offeredSessionTypes, "assessment-call"];
    final disciplines = settings.offeredDisciplines;

    if (_pickingCoach) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _pickingCoach = false);
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BackBar(onBack: () => setState(() => _pickingCoach = false), title: "Choose a coach"),
              const SizedBox(height: 10),
              CoachSearchPicker(
                trainers: trainers,
                selectedId: _trainerId,
                onSelect: (t) => setState(() {
                  _trainerId = t.id;
                  _pickingCoach = false;
                }),
                onCreateCoach: isOwner
                    ? () {
                        Navigator.of(context).pop();
                        ref.read(trainerModeProvider.notifier).go("staff");
                      }
                    : null,
              ),
            ],
          ),
        ),
      );
    }

    final trainerMatches = trainers.where((t) => t.id == _trainerId);
    final trainerName = trainerMatches.isNotEmpty ? trainerMatches.first.displayTitle : null;
    final trainerPhoto = trainerMatches.isNotEmpty ? trainerMatches.first.photo : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(src: _client!.photo, name: _client!.name, size: 32),
              const SizedBox(width: 10),
              Expanded(child: Text(_client!.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
              TextButton(onPressed: () => setState(() => _picking = true), child: const Text("Change", style: TextStyle(fontSize: 12))),
            ],
          ),
          const SizedBox(height: 14),
          Text("COACH", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
            const SizedBox(height: 6),
            TapHighlight(
              onTap: () => setState(() => _pickingCoach = true),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: AppColors.bg, border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(8)),
                child: Row(
                  children: [
                    if (trainerName != null) ...[Avatar(src: trainerPhoto, name: trainerName, size: 26), const SizedBox(width: 8)],
                    Expanded(
                      child: Text(
                        trainerName ?? "Search for a coach…",
                        style: TextStyle(fontSize: 14, color: trainerName == null ? AppColors.mute : AppColors.txt),
                      ),
                    ),
                    Icon(LucideIcons.search, size: 15, color: AppColors.mute),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          Text("SESSION TYPE", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
          const SizedBox(height: 6),
          _ChoiceRow<String>(value: _sessionType, options: types.map((t) => (t, sessionTypeLabel(t))).toList(), onChanged: (v) => setState(() => _sessionType = v ?? _sessionType)),
          if (!isAssessment) ...[
            const SizedBox(height: 12),
            Text("DISCIPLINE", style: TextStyle(fontSize: 10, color: AppColors.mute, letterSpacing: 1)),
            const SizedBox(height: 6),
            _ChoiceRow<String>(value: _discipline, options: disciplines.map((d) => (d, disciplineLabel(d))).toList(), onChanged: (v) => setState(() => _discipline = v ?? _discipline)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FieldLabeled(
                  label: "Date",
                  child: TapHighlight(
                    onTap: _pickDate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(color: AppColors.bg, border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(8)),
                      child: Text(isoDate(_date), style: TextStyle(fontSize: 14, color: AppColors.txt)),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FieldLabeled(
                  label: "Start time",
                  child: TimeField(minutes: _start, onChanged: (v) => setState(() => _start = v)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FieldLabeled(
                  label: "End time (optional)",
                  child: TimeField(
                    minutes: _end,
                    placeholder: "${fmtSlot(_start + 60)} (1 hr)",
                    initialWhenEmpty: _start + 60,
                    onChanged: (v) => setState(() => _end = v),
                    onClear: () => setState(() => _end = null),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12))),
          const SizedBox(height: 16),
          BtnGold(
            full: true,
            onPressed: _saving ? null : _book,
            child: Text(_saving ? "Booking…" : "Book session"),
          ),
        ],
      ),
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({required this.value, required this.options, required this.onChanged});
  final T? value;
  final List<(T, String)> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: options.map((o) {
        final selected = value == o.$1;
        return TapHighlight(
          onTap: () => onChanged(o.$1),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.gold : AppColors.bg,
              border: Border.all(color: selected ? AppColors.gold : AppColors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(o.$2, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? AppColors.onGold : AppColors.txt)),
          ),
        );
      }).toList(),
    );
  }
}
