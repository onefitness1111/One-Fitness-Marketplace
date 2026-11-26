import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/intake_entitlements.dart";
import "../../../core/utils/intake_resubmit.dart";
import "../../../core/utils/notification_triggers.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/intake_forms.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "../../../data/models/client_record.dart";
import "../../../data/models/intake_schema.dart";
import "../shell/client_shell_state.dart";
import "form_filler_screen.dart";
import "intake_answers_screen.dart";
import "physical_assessment_screen.dart";

const _groupIcons = {
  "training": LucideIcons.clipboardCheck,
  "nutrition": LucideIcons.apple,
};
/// Why a given form is locked, in terms of what would unlock it — more use to
/// a client than a bare "locked", since the answer differs per form.
String _unlockHint(String assessmentKey) => switch (assessmentKey) {
  "personalTraining" => "Unlocks with a membership, package, or personalized program.",
  "nutritional" => "Unlocks with a membership, package, personalized program, or nutrition program.",
  "physical" => "Included with a membership or package.",
  _ => "Unlocks with a purchase.",
};

/// The same lock, said to the person it doesn't stop. Staff can open any
/// assessment regardless of what the client has bought, so their version
/// states what the lock actually means — that this isn't part of the plan the
/// client is paying for — rather than reading as a refusal.
String _staffLockNote(AssessmentDef a) => a.physical
    ? "Not included in this client's plan — there's no session to conduct until they buy a membership or package."
    : "Not included in this client's plan — you can still open it to read or record their answers.";

const _assessmentIcons = {
  "personalTraining": LucideIcons.clipboardList,
  "physical": LucideIcons.dumbbell,
  "nutritional": LucideIcons.apple,
};

/// Mirrors IntakeArea.jsx — lists every client-fillable assessment grouped
/// by form, showing OPEN/COMPLETE status, drilling into FormFillerScreen.
/// The Physical Assessment is coach-conducted (a full movement-screening
/// tool, out of scope here) so it's shown as informational only, not opened
/// as an editable form. Reused for both the client's own "Assessments" drawer
/// screen (`who: "client"`, via client_shell.dart) and a coach viewing/editing
/// a client's intake from their Profile tab (`who: "trainer"`, via IntakeTab)
/// — see FormFillerScreen's own doc comment for how `who`/[onSaved] route.
class IntakeAreaScreen extends ConsumerStatefulWidget {
  const IntakeAreaScreen({
    super.key,
    this.initialOpenKey,
    required this.profileId,
    required this.client,
    required this.who,
    required this.onSaved,
  });

  final String? initialOpenKey;
  final String profileId;
  final ClientRecord client;
  final String who; // "client" | "trainer"
  final void Function(String assessmentKey, IntakeRecord) onSaved;

  @override
  ConsumerState<IntakeAreaScreen> createState() => _IntakeAreaScreenState();
}

class _IntakeAreaScreenState extends ConsumerState<IntakeAreaScreen> {
  AssessmentDef? _open;

  /// Whether the open assessment is showing as an editable form rather than
  /// as the client's saved answers. Always true for the client (this is their
  /// own form to fill in) and for staff opening an assessment nobody has
  /// completed yet; staff opening a completed one start on the answers and
  /// opt into editing. Decided when the assessment opens, not re-derived each
  /// build, so that saving — which marks the record complete and rebuilds
  /// this screen — can't swap the editor out from under the coach mid-save.
  bool _editing = true;

  /// Whether the open editor is a fresh submission rather than a correction
  /// of the one on record. Decides whether saving keeps the current answers
  /// as an earlier submission or writes over them.
  bool _fillingAgain = false;

  /// An archived filing opened read-only. viewing 1 is the newest archived.
  ({AssessmentDef form, int viewing})? _archive;

  @override
  void initState() {
    super.initState();
    // Only the client's own self-serve entry point deep-links into a
    // specific form this way (a dashboard onboarding-step tap) — a coach
    // reaching this via IntakeTab always starts on the plain list.
    final pending = widget.who == "client"
        ? ref.read(pendingIntakeFormKeyProvider)
        : null;
    if (pending != null)
      ref.read(pendingIntakeFormKeyProvider.notifier).set(null);
    final key = pending ?? widget.initialOpenKey;
    if (key != null) {
      for (final group in intakeFormsWith(ref.read(liveIntakeFormTemplatesProvider))) {
        for (final a in group.assessments) {
          if (a.key == key) _open = a;
        }
      }
      // Deep-linked straight at one form, so it opens ready to fill in.
      // Tapping a named form is asking to work on it; landing on the
      // read-only view would mean a third tap to get to the same place. The
      // list route still opens completed forms for reading first — see
      // [_opensAsEditor].
      if (_open != null) _editing = true;
    }
  }

  /// A deep link or a tap lands on the editor only where there is nothing to
  /// read back: see [_editing].
  bool _opensAsEditor(AssessmentDef a) =>
      widget.who == "client" || !(widget.client.intake[a.key]?.completed ?? false);

  void _openAssessment(AssessmentDef a) => setState(() {
        _open = a;
        _editing = _opensAsEditor(a);
      });

  void _closeAssessment() => setState(() {
        _open = null;
        _editing = true;
        _fillingAgain = false;
        _archive = null;
      });

  void _beginNew(AssessmentDef form) {
    final done = widget.client.intake[form.key]?.completed ?? false;
    setState(() {
      _archive = null;
      _open = form;
      _editing = true;
      _fillingAgain = done;
    });
  }

  Future<void> _noteRefresh(String key, {required bool fresh}) async {
    if (!fresh) return;
    final kind = programRefreshKind(key);
    if (kind == null) return;
    final at = stamp();
    if (widget.who == "client") {
      ref.read(clientRecordProvider.notifier).update(
            (r) => r.copyWith(programRefresh: {...r.programRefresh, kind: at}),
          );
    } else {
      ref.read(trainerClientRecordsProvider.notifier).update(
            widget.profileId,
            (r) => r.copyWith(programRefresh: {...r.programRefresh, kind: at}),
          );
    }
    await SupabaseService.flagProgramRefresh(widget.profileId, kind);
    final named = widget.who == "client"
        ? ref.read(clientInfoProvider).name
        : ref.read(trainerRosterProvider).where((c) => c.id == widget.profileId).map((c) => c.name).firstOrNull;
    notifyOwnerInternal(
      title: programRefreshLabel(kind, forOwner: true),
      body: "${(named ?? "").trim().isEmpty ? "A client" : named} filed a new intake.",
    );
  }

  /// Writes the movement screen beside `completed` rather than inside
  /// `answers`, matching the shape the web app writes and
  /// generate-ai-workout-program reads.
  Future<void> _savePhysical(String assessmentKey, Map<String, dynamic> payload) async {
    final prior = widget.client.intake[assessmentKey];
    // Every completed save is a new filing now (L3), so the owner is always
    // told the newest one is in.
    const fresh = true;
    final record = IntakeRecord(
      answers: prior?.answers ?? const {},
      completed: true,
      at: stamp(),
      by: "Trainer/Coach",
      attachments: _fillingAgain ? const [] : (prior?.attachments ?? const []),
      extra: _fillingAgain ? payload : {...?prior?.extra, ...payload},
    );
    final IntakeRecord saved;
    try {
      // The server keeps the assessment already on record as an earlier
      // filing before writing this one (L3), all in one transaction (L5).
      saved = await SupabaseService.updateClientIntake(
        widget.profileId,
        assessmentKey,
        record,
      );
      await _noteRefresh(assessmentKey, fresh: fresh);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(intakeSaveFailedMessage)),
      );
      return;
    }
    widget.onSaved(assessmentKey, saved);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Assessment saved.")));
    _closeAssessment();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;

    // Computed before the open-form branch so a deep link (the dashboard's
    // onboarding prompt sets pendingIntakeFormKeyProvider, which initState
    // turns straight into an open form) can't route around the lock the list
    // below applies.
    final isClientView = widget.who == "client";
    final info = isClientView
        ? ref.watch(clientInfoProvider)
        : ref.watch(trainerRosterProvider).where((c) => c.id == widget.profileId).firstOrNull;
    final entitlements = info == null
        ? IntakeEntitlements.none
        : computeIntakeEntitlements(info: info, allPlans: ref.watch(membershipPlansProvider));

    if (_open != null && isClientView && !entitlements.allows(_open!.key)) {
      // Shouldn't be reachable through the UI, but a stale deep link (or a
      // purchase that lapsed between tap and build) would otherwise drop them
      // into a form they're not entitled to fill in.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeAssessment();
      });
      return const SizedBox.shrink();
    }

    final archive = _archive;
    if (archive != null) {
      final past = client.intake[archive.form.key];
      if (past == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _archive = null);
        });
      } else if (archive.form.schema != null) {
        return LocalBackScope(
          isOpen: true,
          onBack: () => setState(() => _archive = null),
          child: IntakeAnswersScreen(
            schema: archive.form.schema!,
            schemaFor: (version) =>
                templateVersionFor(archive.form.key, version, ref.read(intakeFormTemplatesProvider))?.schema ??
                archive.form.schema!,
            record: past,
            profileId: widget.profileId,
            assessmentKey: archive.form.key,
            initialViewing: archive.viewing,
            readOnly: true,
            onBack: () => setState(() => _archive = null),
            onEdit: () {},
          ),
        );
      } else {
        final item = archive.viewing > 0 && archive.viewing <= past.history.length
            ? past.history[archive.viewing - 1]
            : null;
        final summary = item?.extra["coachSummary"]?.toString() ?? past.extra["coachSummary"]?.toString() ?? "";
        return LocalBackScope(
          isOpen: true,
          onBack: () => setState(() => _archive = null),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BackBar(onBack: () => setState(() => _archive = null)),
                const SizedBox(height: 10),
                Text(archive.form.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                const SizedBox(height: 6),
                Text(
                  "Completed by ${item?.by ?? past.by ?? "Coach"} · ${item?.at ?? past.at ?? ""}",
                  style: TextStyle(fontSize: 12, color: AppColors.mute),
                ),
                const SizedBox(height: 14),
                Text(
                  summary.trim().isEmpty ? "This movement screen was kept as it was recorded." : summary.trim(),
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
        );
      }
    }

    if (_open != null) {
      final a = _open!;
      // Staff record the movement screen; the client sees what it is. This
      // is a thing done TO a client by a coach, so there's nothing for them
      // to fill in — but there was nothing for the coach to fill in either
      // until now, and the screen lived on paper.
      if (a.physical && !isClientView) {
        return LocalBackScope(
          isOpen: true,
          onBack: _closeAssessment,
          child: PhysicalAssessmentScreen(
            isOwner: ref.watch(trainerAuthProvider) == "owner",
            existing: client.intake[a.key],
            clientName: info?.name.isNotEmpty == true ? info!.name : "this client",
            onBack: _closeAssessment,
            onSave: (payload) => _savePhysical(a.key, payload),
          ),
        );
      }
      if (a.physical) {
        return LocalBackScope(
          isOpen: true,
          onBack: _closeAssessment,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BackBar(onBack: _closeAssessment),
                const SizedBox(height: 10),
                const SectionLabel("Free Physical Assessment Session"),
                HintBox(
                  text: isClientView
                      ? "This is a hands-on movement assessment conducted by your coach during your first training "
                            "session — there's nothing to fill out here yourself. Book it from the Dashboard or Booking tab."
                      : "A hands-on movement assessment you conduct in person during the client's first training "
                            "session. There's no form behind it — record what you find in Notes or Measurements.",
                ),
              ],
            ),
          ),
        );
      }

      final record = client.intake[a.key];
      if (!_editing && record != null) {
        // Staff reading a completed intake. Backing out goes to the list;
        // "Edit answers" swaps in the form below, which backs out to here.
        return LocalBackScope(
          isOpen: true,
          onBack: _closeAssessment,
          child: IntakeAnswersScreen(
            schema: a.schema!,
            // Each submission is read back against the version of the form it
            // was given against, so revising a gym form never changes what an
            // earlier client appears to have been asked.
            schemaFor: (version) =>
                templateVersionFor(a.key, version, ref.read(intakeFormTemplatesProvider))?.schema ??
                a.schema!,
            record: record,
            profileId: widget.profileId,
            assessmentKey: a.key,
            onBack: _closeAssessment,
            onEdit: () => setState(() {
              _editing = true;
              _fillingAgain = false;
            }),
            // Coaches only: a client re-opening their own intake is almost
            // always correcting something they just typed, not starting a
            // fresh one.
            onFillAgain: () => setState(() {
              _editing = true;
              _fillingAgain = true;
            }),
          ),
        );
      }

      // Back from the editor returns to the answers whenever there are any to
      // return to — which, after a save, there now are: the coach sees what
      // they just recorded rather than being dropped back to the list.
      final hasAnswersBehind = !isClientView && (record?.completed ?? false);
      final leaveEditor = hasAnswersBehind
          ? () => setState(() {
                _editing = false;
                _fillingAgain = false;
              })
          : _closeAssessment;
      return LocalBackScope(
        isOpen: true,
        onBack: leaveEditor,
        child: FormFillerScreen(
          assessmentKey: a.key,
          schema: a.schema!,
          onBack: leaveEditor,
          profileId: widget.profileId,
          client: client,
          who: widget.who,
          onSaved: (record) {
            widget.onSaved(a.key, record);
            _noteRefresh(a.key, fresh: true);
            // A client who has bought nothing has just told the gym what they
            // want out of training. Choosing a plan is the next thing they
            // came to do, so take them there rather than returning them to a
            // list of forms they've now finished.
            if (isClientView && !entitlements.hasAnyPurchase && record.completed) {
              ref.read(clientScreenProvider.notifier).go("memberships");
            }
          },
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nothing bought yet — the forms below are all locked, so say why
          // once at the top and hand them the way out, rather than leaving
          // them to tap a locked row to find out.
          if (isClientView && !entitlements.hasAnyPurchase)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: AppCard(
                borderColor: AppColors.goldDim,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Choose a plan to get started",
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Your intake forms unlock once you have a membership, package or program. What you buy decides which "
                      "forms you fill in — a membership or package opens all of them, a personalized program opens training "
                      "and nutrition, and a nutrition program opens nutrition.",
                      style: TextStyle(fontSize: 11.5, color: AppColors.mute, height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    BtnGold(
                      full: true,
                      onPressed: () => ref.read(clientScreenProvider.notifier).go("memberships"),
                      child: const Text("Go to Access Hub"),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: BtnGhost(
              full: true,
              onPressed: () => _chooseNewIntake(isClientView, entitlements),
              child: const Text("Start new intake"),
            ),
          ),
          ...intakeFormsWith(ref.watch(liveIntakeFormTemplatesProvider)).map((group) {
          final visible = group.assessments
              .where((a) => a.clientCanFill || a.physical)
              // The coach-run physical assessment comes with a membership or
              // package; with only a program (or nothing) there's no session
              // to conduct, so it isn't part of this client's intake at all.
              // Staff still see it listed: hiding a whole assessment from the
              // person who conducts it makes their roster look inconsistent
              // from one client to the next, with nothing on screen to
              // explain why. They get it greyed out with the reason instead.
              .where((a) => !a.physical || entitlements.physical || !isClientView)
              .toList();
          if (visible.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _groupIcons[group.key] ?? LucideIcons.clipboardList,
                      size: 17,
                      color: AppColors.gold,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      group.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...visible.map((a) {
                  final rec = client.intake[a.key];
                  final done = rec?.completed ?? false;
                  // Locked forms stay listed — seeing what's on offer is the
                  // point — but a client can't open one until a purchase
                  // entitles them. A coach is never blocked: they may need to
                  // record answers for a client mid-signup, so on their side
                  // the lock is shown as information only.
                  final locked = !entitlements.allows(a.key);
                  final blocked = locked && isClientView;
                  return AppCard(
                    padding: EdgeInsets.zero,
                    // A locked row sends them where the lock is actually
                    // lifted, rather than being inert — tapping something
                    // and getting nothing back reads as a broken screen,
                    // and the answer ("buy a plan") is one tap away.
                    onTap: blocked
                        ? () => ref.read(clientScreenProvider.notifier).go("memberships")
                        : () => _openAssessment(a),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(
                            // The padlock is for the person it actually stops.
                            // Staff can open any of these, so showing them a
                            // padlock and a LOCKED badge sends them away from
                            // a form they were free to read all along.
                            blocked
                                ? LucideIcons.lock
                                : (_assessmentIcons[a.key] ?? LucideIcons.clipboardList),
                            size: 16,
                            color: AppColors.mute,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    "Conducted by: ${a.by}",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppColors.mute,
                                    ),
                                  ),
                                ),
                                if (done && rec?.at != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      "Completed by ${rec!.by} · ${rec.at}",
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.gold,
                                      ),
                                    ),
                                  ),
                                if (locked)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      isClientView
                                          // Tapping goes to the Membership
                                          // Hub, so say so — otherwise the
                                          // row looks like a dead end.
                                          ? "${_unlockHint(a.key)} Tap to choose a plan."
                                          : _staffLockNote(a),
                                      style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.35),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: done
                                  ? AppColors.gold
                                  : Colors.transparent,
                              border: Border.all(
                                color: done
                                    ? AppColors.goldDim
                                    : AppColors.line,
                              ),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              // Staff get the status that tells them whether
                              // there is anything to read; "LOCKED" would
                              // hide that a completed form is sitting there.
                              blocked ? "LOCKED" : (done ? "COMPLETE" : "OPEN"),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: done ? AppColors.onGold : AppColors.mute,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            LucideIcons.chevronRight,
                            size: 16,
                            color: AppColors.mute,
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          );
        }),
        _archivedSection(isClientView),
        ],
      ),
    );
  }

  List<AssessmentDef> _formsFor(bool isClientView, IntakeEntitlements entitlements) {
    final forms = <AssessmentDef>[];
    for (final group in intakeFormsWith(ref.read(liveIntakeFormTemplatesProvider))) {
      for (final form in group.assessments) {
        if (form.physical && isClientView) continue;
        if (!form.physical && !form.clientCanFill && isClientView) continue;
        if (isClientView && !entitlements.allows(form.key)) continue;
        if (!form.physical && form.schema == null) continue;
        forms.add(form);
      }
    }
    return forms;
  }

  Future<void> _chooseNewIntake(bool isClientView, IntakeEntitlements entitlements) async {
    final forms = _formsFor(isClientView, entitlements);
    if (!mounted) return;
    if (forms.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("There isn't a form you can start right now.")),
      );
      return;
    }
    final picked = await showModalBottomSheet<AssessmentDef>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Text("Start new intake", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            for (final form in forms)
              ListTile(
                title: Text(form.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text("Conducted by: ${form.by}", style: TextStyle(color: AppColors.mute, fontSize: 12)),
                onTap: () => Navigator.pop(ctx, form),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _beginNew(picked);
  }

  Widget _archivedSection(bool isClientView) {
    final rows = <({AssessmentDef form, int viewing, String at, String by})>[];
    // Retired gym forms are included: a form that is no longer offered still
    // has answers on file, and those stay readable here (U1, L3).
    final liveKeys = {for (final t in ref.watch(liveIntakeFormTemplatesProvider)) t.key};
    final everyForm = newestOfEachTemplate(ref.watch(intakeFormTemplatesProvider));
    for (final group in intakeFormsWith(everyForm)) {
      for (final form in group.assessments) {
        if (form.physical && isClientView) continue;
        final record = widget.client.intake[form.key];
        if (record == null) continue;
        final retired = group.key == "custom" && !liveKeys.contains(form.key);
        if (retired && record.completed) {
          rows.add((form: form, viewing: 0, at: record.at ?? "", by: record.by ?? "Client"));
        }
        for (var i = 0; i < record.history.length; i++) {
          final past = record.history[i];
          rows.add((form: form, viewing: i + 1, at: past.at ?? "", by: past.by ?? "Client"));
        }
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    rows.sort((a, b) => b.at.compareTo(a.at));
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: AppColors.line),
      child: ExpansionTile(
        initiallyExpanded: false,
        iconColor: AppColors.mute,
        collapsedIconColor: AppColors.mute,
        tilePadding: EdgeInsets.zero,
        title: Text(
          "Archived (${rows.length})",
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                padding: EdgeInsets.zero,
                onTap: () => setState(() => _archive = (form: row.form, viewing: row.viewing)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Icon(LucideIcons.history, size: 16, color: AppColors.mute),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(row.form.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                            const SizedBox(height: 2),
                            Text(
                              "Completed by ${row.by}${row.at.isEmpty ? "" : " · ${row.at}"}",
                              style: TextStyle(fontSize: 12, color: AppColors.mute),
                            ),
                          ],
                        ),
                      ),
                      Icon(LucideIcons.chevronRight, size: 16, color: AppColors.mute),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
