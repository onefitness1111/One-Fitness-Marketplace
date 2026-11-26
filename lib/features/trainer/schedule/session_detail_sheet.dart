import "../../../data/providers/platform_settings_provider.dart";
import "single_session_staff.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/supabase/supabase_service.dart";
import "balance_booking_warning.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_limits.dart";
import "../../../core/utils/booking_utils.dart" hide findTrainerConflict;
import "../../../core/utils/late_fee_notice.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/utils/membership_utils.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/utils/onboarding_utils.dart";
import "../../../core/utils/scheduling_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/client_info.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "client_search_picker.dart";
import "override_prompt.dart";

/// Mirrors SessionDetail.jsx — the roster of every client in one
/// trainer+date+slot group, with add/remove-client and cancel actions.
Future<void> showSessionDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required String trainerId,
  required String date,
  required int slot,
  required void Function(String clientId) onOpenClient,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _SessionDetailBody(trainerId: trainerId, date: date, slot: slot, onOpenClient: onOpenClient),
    ),
  );
}

class _SessionDetailBody extends ConsumerStatefulWidget {
  const _SessionDetailBody({required this.trainerId, required this.date, required this.slot, required this.onOpenClient});
  final String trainerId;
  final String date;
  final int slot;
  final void Function(String clientId) onOpenClient;

  @override
  ConsumerState<_SessionDetailBody> createState() => _SessionDetailBodyState();
}

class _SessionDetailBodyState extends ConsumerState<_SessionDetailBody> {
  bool _adding = false;
  bool _busy = false;

  void _showError() {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save — check your connection and try again.")));
  }

  String _rosterName(String clientId) {
    final matches = ref
        .read(trainerRosterProvider)
        .where((c) => c.id == clientId);
    return matches.isEmpty ? "another client" : matches.first.name;
  }

  Future<void> _addClient(
    ClientInfo client, {
    required Booking session,
    required CapacityInfo cap,
    required String trainerName,
    required bool isOwner,
    required List<Booking> allBookings,
  }) async {
    if (!await confirmStaffBalanceAdd(
          context,
          clientId: client.id,
          isOwner: isOwner,
        ) ||
        !mounted)
      return;

    final conflict = findTrainerConflict(
      allBookings,
      widget.trainerId,
      widget.date,
      widget.slot,
      session.sessionType,
      session.discipline,
    );
    String? overrideReason;
    if (conflict != null) {
      if (!isOwner) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(coachOverlapRefusal)));
        return;
      }
      final message = ownerOverlapOverrideMessage(
        coachName: trainerName,
        conflictSlot: conflict.slot,
        clientName: _rosterName(conflict.clientId),
      );
      final ok = await confirmOwnerOverride(
        context,
        title: "Scheduling conflict",
        message: message,
      );
      if (!ok || !mounted) return;
      overrideReason = overrideReasonFor(
        BookingLimitKind.overlap,
        detail: overrideDetail(message),
      );
    }

    // Adding past the class limit is allowed — staff know the room — but
    // never silently. The count is what it will be once this client is in.
    // An overlap override already stamps the insert, and that stamp is what
    // the trigger accepts for a full class too.
    if (cap.atCap && overrideReason == null) {
      if (!isOwner) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "This ${sessionTypeLabel(session.sessionType)} session is at its limit of ${cap.cap} — only the owner can add past it.",
            ),
          ),
        );
        return;
      }
      final message = ownerCapacityOverrideMessage(
        clientName: client.name,
        count: cap.count,
        cap: cap.cap,
      );
      final go = await confirmOwnerOverride(
        context,
        title: "Session at capacity",
        message: message,
      );
      if (!go || !mounted) return;
      overrideReason = overrideReasonFor(
        BookingLimitKind.capacity,
        detail: overrideDetail(message),
      );
    }

    setState(() => _adding = false);
    final planId = planToChargeFor(
      client,
      session.sessionType,
      allBookings,
      ref.read(membershipPlansProvider),
    );

    Future<void> insert(String? reason) async {
      var draft = Booking(
        id: "",
        clientId: client.id,
        trainerId: widget.trainerId,
        date: widget.date,
        slot: widget.slot,
        sessionType: session.sessionType,
        discipline: session.discipline,
        planId: planId,
        durationMin: session.durationMin,
      );
      if (reason != null) draft = draft.withOwnerOverride(reason);
      final saved = await SupabaseService.insertBooking(draft);
      ref.read(allBookingsProvider.notifier).addBooking(saved);
      notifyPush(
        profileId: client.id,
        title: "Session booked",
        body:
            "You're booked for ${niceDate(widget.date)} at ${fmtSlot(widget.slot)} with $trainerName.",
        sms: true,
      );
      if (planId == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "${client.name} has no active plan covering ${sessionTypeLabel(session.sessionType)} — booked, but no session was deducted.",
            ),
          ),
        );
      }
    }

    if (planId == null &&
        !client.isStaff &&
        overrideReason == null &&
        !session.sessionType.startsWith("assessment")) {
      final out = await bookClientWithoutPlan(
        context: context,
        clientName: client.name,
        clientId: client.id,
        sessionType: session.sessionType,
        trainerId: widget.trainerId,
        date: widget.date,
        slot: widget.slot,
        discipline: session.discipline,
        priceCents: ref
            .read(platformSettingsProvider)
            .singleSessionPriceFor(session.sessionType),
        isOwner: isOwner,
      );
      if (out == null || !mounted) return;
      if (out.status == "requested") {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(out.message ?? "Sent to the owner.")),
        );
        return;
      }
      if (!out.booked) {
        final fresh = findTrainerConflict(
          ref.read(allBookingsProvider),
          widget.trainerId,
          widget.date,
          widget.slot,
          session.sessionType,
          session.discipline,
        );
        final retry = await offerBookingOverride(
          context,
          error: out.message ?? "",
          isOwner: isOwner,
          alreadyOverriding: false,
          unspecifiedFull:
              out.full && classifyBookingLimitError(out.message ?? "") == null,
          coachName: trainerName,
          addingClientName: client.name,
          conflictSlot: fresh?.slot,
          conflictingClientName: fresh == null
              ? null
              : _rosterName(fresh.clientId),
          capacityCount: cap.atCap ? cap.count : null,
          capacityCap: cap.atCap ? cap.cap : null,
          refunded: out.refunded,
        );
        if (!mounted) return;
        if (!retry.go) {
          if (retry.declined) {
            if (out.full && out.refunded) {
              await showFilledRefundDialog(
                context,
                singleSessionFailureMessage(out),
              );
            }
            return;
          }
          if (out.full && out.refunded) {
            await showFilledRefundDialog(
              context,
              singleSessionFailureMessage(out),
            );
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(singleSessionFailureMessage(out))),
            );
          }
          return;
        }
        overrideReason = retry.reason;
      } else {
        final made = await SupabaseService.loadBookingById(out.bookingId!);
        if (made != null)
          ref.read(allBookingsProvider.notifier).addBooking(made);
        notifyPush(
          profileId: client.id,
          title: "Session booked",
          body:
              "You're booked for ${niceDate(widget.date)} at ${fmtSlot(widget.slot)} with $trainerName.",
          sms: true,
        );
        return;
      }
    }

    try {
      await insert(overrideReason);
    } catch (e) {
      final text = e.toString();
      if (isUnpaidBalanceError(e) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(staffBalanceWarningFromError(text))),
        );
        return;
      }
      if (!mounted) return;
      final fresh = findTrainerConflict(
        ref.read(allBookingsProvider),
        widget.trainerId,
        widget.date,
        widget.slot,
        session.sessionType,
        session.discipline,
      );
      final retry = await offerBookingOverride(
        context,
        error: e,
        isOwner: isOwner,
        alreadyOverriding: overrideReason != null,
        coachName: trainerName,
        addingClientName: client.name,
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(staffBookingFailureMessage(e))));
        return;
      }
      try {
        await insert(retry.reason);
      } catch (e2) {
        if (!mounted) return;
        final again = e2.toString();
        if (isUnpaidBalanceError(e2)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(staffBalanceWarningFromError(again))),
          );
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(staffBookingFailureMessage(e2))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allBookings = ref.watch(allBookingsProvider);
    final roster = ref.watch(trainerRosterProvider);
    final trainers = ref.watch(trainersProvider);
    final active = sessionGroup(allBookings, widget.trainerId, widget.date, widget.slot);
    if (active.isEmpty) return const SizedBox.shrink();
    final first = active.first;
    final cap = capacityInfo(allBookings, widget.trainerId, widget.date, widget.slot, first.sessionType);
    final trainerMatch = trainers.where((t) => t.id == widget.trainerId);
    final trainerName = trainerMatch.isNotEmpty ? trainerMatch.first.displayTitle : "Coach";
    final isOwner = ref.watch(trainerAuthProvider) == "owner";
    final isPast = widget.date.compareTo(isoToday()) < 0;

    if (_adding) {
      // This whole sheet is a real showModalBottomSheet — a genuine
      // Navigator route the shell's own back handling (LocalBackScope)
      // can't see. Without this PopScope, hardware back / an OS edge-swipe
      // while "Add a client" is open would dismiss the ENTIRE sheet
      // instead of just backing out of this one sub-view.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _adding = false);
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BackBar(onBack: () => setState(() => _adding = false), title: "Add a client"),
            const SizedBox(height: 10),
            ClientSearchPicker(
              roster: roster,
              exclude: active.map((b) => b.clientId).toList(),
              onSelect: (c) => _addClient(
                c,
                session: first,
                cap: cap,
                trainerName: trainerName,
                isOwner: isOwner,
                allBookings: allBookings,
              ),
            ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reads top-down the way staff think about a session: what it
          // is, who's running it, then when.
          Row(
            children: [
              Expanded(child: Text(sessionTypeLabel(first.sessionType), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              Tag(text: "${cap.count}/${cap.cap}", gold: !cap.atCap),
            ],
          ),
          const SizedBox(height: 2),
          Text("${disciplineLabel(first.discipline)} · $trainerName", style: TextStyle(fontSize: 13, color: AppColors.txt)),
          const SizedBox(height: 2),
          Text("${dayLabel(widget.date)} · ${fmtSlot(widget.slot)} – ${fmtSlot(widget.slot + first.durationMin)}", style: TextStyle(fontSize: 12, color: AppColors.mute)),
          const SizedBox(height: 14),
          ...active.map((b) {
            final matches = roster.where((c) => c.id == b.clientId);
            final client = matches.isNotEmpty ? matches.first : null;
            // Which intake answers this client is still missing, if any.
            // Read here rather than passed in because the roster is the one
            // place a coach sees who is actually turning up, and that's when
            // a missing questionnaire is worth knowing about.
            final clientRecord = ref.watch(trainerClientRecordsProvider)[b.clientId];
            final missingIntake =
                clientRecord == null ? const <String>[] : incompleteIntakeTitles(clientRecord);
            return AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Avatar(src: client?.photo, name: client?.name ?? "Removed", size: 34),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TapHighlight(
                          onTap: client != null
                              ? () {
                                  Navigator.of(context).pop();
                                  widget.onOpenClient(client.id);
                                }
                              : null,
                          child: Text(client?.name ?? "Removed client", style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        ),
                      ),
                      if (missingIntake.isNotEmpty)
                        Tooltip(
                          message: missingIntake.length == 1
                              ? "Hasn't completed their ${missingIntake.first}"
                              : "Hasn't completed: ${missingIntake.join(", ")}",
                          triggerMode: TooltipTriggerMode.tap,
                          child: Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              LucideIcons.clipboardX,
                              size: 16,
                              color: AppColors.gold,
                              semanticLabel: "Incomplete intake",
                            ),
                          ),
                        ),
                      if (!isPast)
                        IconButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  setState(() => _busy = true);
                                  try {
                                    await SupabaseService.deleteBooking(b.id, archive: true);
                                    ref.read(allBookingsProvider.notifier).cancelBooking(b.id);
                                    notifyPush(profileId: b.clientId, title: "Appointment canceled", body: "Your session on ${niceDate(b.date)} at ${fmtSlot(b.slot)} was canceled.", sms: true);
                                  } catch (e) {
                                    _showError();
                                  } finally {
                                    if (mounted) setState(() => _busy = false);
                                  }
                                },
                          icon: Icon(LucideIcons.userMinus, size: 15, color: AppColors.danger),
                        ),
                    ],
                  ),
                  if (client != null) ...[
                    const SizedBox(height: 9),
                    if (b.attendanceStatus != null)
                      _MarkedAttendanceTag(status: b.attendanceStatus!)
                    else
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: kAttendanceOptions.map((opt) {
                          return TapHighlight(
                            onTap: () {
                              ref.read(allBookingsProvider.notifier).updateAttendance(b.id, opt.key);
                              final marked = SupabaseService.updateBookingAttendance(b.id, opt.key).catchError((Object _) {
                                ref.read(allBookingsProvider.notifier).updateAttendance(b.id, null);
                                return null;
                              });
                              if (opt.key == "checked-in") {
                                final total = ref.read(allBookingsProvider).where((x) => x.clientId == client.id && x.attendanceStatus == "checked-in").length;
                                notifySessionMilestoneIfCrossed(toEmail: client.email ?? "", toName: client.name, totalCheckedIn: total, profileId: client.id);
                              }
                              if (opt.key == "early-cancel" || opt.key == "late-cancel" || opt.key == "no-show") {
                                final settings = ref.read(platformSettingsProvider);
                                final coaches = ref.read(trainersProvider).where((t) => t.id == b.trainerId);
                                final coachName = coaches.isEmpty ? "Your coach" : coaches.first.displayTitle;
                                final window = cancelWindow(
                                  b,
                                  lateCancellationHours: settings.lateCancellationHours,
                                  noShowCancelHours: settings.noShowCancelHours,
                                );
                                final cents = opt.key == "no-show"
                                    ? settings.noShowFeeCents
                                    : opt.key == "late-cancel"
                                        ? cancelFeeCentsFor(
                                            window,
                                            lateCents: settings.lateCancellationFeeCents,
                                            closeCents: settings.noShowFeeCents,
                                          )
                                        : 0;
                                marked.then((fee) {
                                  if (fee?["balanceRecorded"] == true) return;
                                  notifyPush(
                                    profileId: b.clientId,
                                    title: opt.key == "no-show" ? "No-show fee" : "Session updated",
                                    body: attendanceMarkedNotice(coachName: coachName, status: opt.key, cents: cents),
                                    sms: true,
                                  );
                                });
                              }
                            },
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                              decoration: BoxDecoration(
                                border: Border.all(color: AppColors.line),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(opt.label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.mute)),
                            ),
                          );
                        }).toList(),
                      ),
                  ],
                ],
              ),
            );
          }),
          if (!isPast) ...[
            const SizedBox(height: 6),
            BtnGhost(full: true, onPressed: () => setState(() => _adding = true), child: const Text("Add a client")),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: active.isEmpty || _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        for (final b in active) {
                          await SupabaseService.deleteBooking(b.id, archive: true);
                          ref.read(allBookingsProvider.notifier).cancelBooking(b.id);
                          notifyPush(profileId: b.clientId, title: "Appointment canceled", body: "Your session on ${niceDate(b.date)} at ${fmtSlot(b.slot)} was canceled.", sms: true);
                        }
                        if (context.mounted) Navigator.of(context).pop();
                      } catch (e) {
                        _showError();
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.errorText, side: BorderSide(color: AppColors.danger), minimumSize: Size.fromHeight(44)),
              child: Text(_busy ? "Cancelling…" : "Cancel session"),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shown in place of the attendance-option buttons once a client's booking
/// already has a status — mirrors the user's explicit ask: "If the client
/// is already marked then no options will appear."
class _MarkedAttendanceTag extends StatelessWidget {
  const _MarkedAttendanceTag({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final opt = kAttendanceOptions.firstWhere((o) => o.key == status, orElse: () => kAttendanceOptions.first);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: opt.color), borderRadius: BorderRadius.circular(6)),
      child: Text(opt.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: opt.color)),
    );
  }
}
