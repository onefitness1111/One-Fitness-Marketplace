import "../../../core/widgets/animated_screen_switcher.dart";
import "../../../core/widgets/segmented_toggle.dart";
import "../../../core/widgets/tap_highlight.dart";
import "visits_tab.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../data/providers/program_draft_request.dart";
import "../../../data/providers/trainer_providers.dart";
import "../chat/coach_chat_screen.dart";
import "../dashboard/live_workouts_card.dart";
import "../schedule/add_manual_booking_sheet.dart";
import "../shell/trainer_shell_state.dart";
import "documents_tab.dart";
import "habits_tab.dart";
import "intake_tab.dart";
import "logged_tab.dart";
import "notes_tab.dart";
import "plans_tab.dart";
import "merit_badges_tab.dart";
import "points_tab.dart";
import "profile_tab.dart";
import "progress_tab.dart";
import "squad_tab.dart";

class _TabDef {
  const _TabDef(this.key, this.label, this.icon);
  final String key;
  final String label;
  final IconData icon;
}

const _primary = [
  _TabDef("profile", "Profile", LucideIcons.user),
  _TabDef("plans", "Plans", LucideIcons.clipboardList),
  _TabDef("logs", "Logged", LucideIcons.history),
  _TabDef("progress", "Progress", LucideIcons.image),
];

/// Everything that is not on the top bar. Photos and measurements live
/// together on Progress. Assessments stays here and is also opened
/// straight from a profile row. Merit Badges opens the full badge screen.
const _moreTabs = [
  _TabDef("visits", "Visits", LucideIcons.calendarCheck),
  _TabDef("intake", "Assessments", LucideIcons.clipboardCheck),
  _TabDef("documents", "Documents", LucideIcons.fileSignature),
  _TabDef("habits", "Habits", LucideIcons.flame),
  _TabDef("notes", "Notes", LucideIcons.flag),
  _TabDef("squad", "Squad", LucideIcons.users2),
  _TabDef("points", "Points", LucideIcons.gift),
  _TabDef("badges", "Merit Badges", LucideIcons.award),
];

/// The per-client view: five top tabs, a short activity line, and quick actions.
class TrainerView extends ConsumerStatefulWidget {
  const TrainerView({super.key, required this.clientId});

  final String clientId;

  @override
  ConsumerState<TrainerView> createState() => _TrainerViewState();
}

class _TrainerViewState extends ConsumerState<TrainerView> {
  String _tab = "profile";
  bool _composeNote = false;

  /// Plans' own sub-tab. Kept here so it's part of [_history] below.
  String _plansSub = "training";

  /// Every (tab, sub-tab) position visited on this client, oldest first,
  /// so back retraces them: Profile → Plans/Training → Nutrition →
  /// Programs unwinds Programs → Nutrition → Training → Profile. Once it's
  /// empty, back falls through to the shell (Clients → Dashboard).
  final List<(String, String)> _history = [];

  void _visit(String tab, String sub) {
    if (tab == _tab && sub == _plansSub) return;
    // A plain stack, same as the shell: Profile → Plans → Profile unwinds
    // to Plans, then Profile.
    _history.add((_tab, _plansSub));
    if (_history.length > 50) _history.removeAt(0);
    setState(() {
      _tab = tab;
      _plansSub = sub;
    });
  }

  void _back() {
    if (_history.isEmpty) return;
    final (tab, sub) = _history.removeLast();
    setState(() {
      _tab = tab;
      _plansSub = sub;
    });
  }

  @override
  void initState() {
    super.initState();
    // trainerClientRecordsProvider is only ever bulk-loaded once, at sign-in
    // — nothing refreshes it afterward (no realtime subscription on
    // client_records), so a program/nutrition/etc. change made elsewhere
    // (e.g. the web app, in a separate session) after this coach signed in
    // would sit invisible for the rest of the app session. Re-fetching this
    // one client's record whenever a coach opens them (this only runs once
    // per TrainerView instance, since clients_screen.dart keys it by
    // clientId) keeps every tab here current without refetching the whole
    // roster.
    _refreshRecord();
  }

  Future<void> _refreshRecord() async {
    final baseline = ref.read(trainerClientRecordsProvider)[widget.clientId];
    try {
      final fresh = await SupabaseService.loadClientRecord(widget.clientId);
      if (!mounted) return;
      // If a note/program/etc. was added locally while this fetch was in
      // flight, the provider entry is no longer the same object we started
      // from — applying this now-stale snapshot on top would silently wipe
      // out that edit from the UI (it'd still be saved server-side, but
      // would look "gone" to the coach). Skip the refresh in that case.
      final current = ref.read(trainerClientRecordsProvider)[widget.clientId];
      if (!identical(current, baseline)) return;
      ref
          .read(trainerClientRecordsProvider.notifier)
          .update(widget.clientId, (_) => fresh);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant TrainerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clientId != widget.clientId) {
      _history.clear();
      setState(() {
        _tab = "profile";
        _plansSub = "training";
      });
    }
  }

  // Opening Plans always lands on Training, whatever was showing last time.
  void _goTab(String k) => _go(k, null);

  /// Which intake form to open on arriving at the Intake tab, set by a tap on
  /// the Profile tab's assessment list.
  ///
  /// Tapping "Personalized Training Intake" there used to land on the list of
  /// forms, so opening the thing you tapped took two taps and a second look
  /// at the same three rows. It now opens that form directly.
  String? _intakeKey;

  /// Opens that one form. Reached only from the Profile tab's rows.
  void _goToIntakeForm(String assessmentKey) => _go("intake", assessmentKey);

  /// Every tab change clears the pending form, so reaching Intake any other
  /// way — the tab bar, the back stack — starts on the list as it always did.
  void _go(String k, String? intakeKey) {
    _intakeKey = intakeKey;
    _visit(k, k == "plans" ? "training" : _plansSub);
  }

  Widget _quickActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: _QuickActions(
        onMessage: _message,
        onBook: _book,
        onLog: _logWorkout,
        onNote: _addNote,
      ),
    );
  }

  void _message() {
    ref.read(coachChatOpenRequestProvider.notifier).open(widget.clientId);
    ref.read(trainerModeProvider.notifier).go("chat");
  }

  void _book() {
    showAddManualBookingSheet(
      context,
      ref,
      initialDate: isoToday(),
      initialClientId: widget.clientId,
    );
  }

  void _logWorkout() {
    final matches = ref
        .read(trainerRosterProvider)
        .where((c) => c.id == widget.clientId);
    final name = matches.isEmpty ? "Client" : matches.first.name;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            LiveWorkoutPage(clientId: widget.clientId, clientName: name),
      ),
    );
  }

  void _addNote() {
    setState(() => _composeNote = true);
    _go("notes", null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _composeNote) setState(() => _composeNote = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeInMore = _tab == "more" || _moreTabs.any((t) => t.key == _tab);

    return LocalBackScope(
      isOpen: _history.isNotEmpty,
      onBack: _back,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            key: const Key("client-tabs"),
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: SegmentedToggle(
              labels: [..._primary.map((t) => t.label), "More"],
              index: activeInMore
                  ? _primary.length
                  : _primary.indexWhere((t) => t.key == _tab).clamp(0, _primary.length),
              onChanged: (i) => _goTab(i >= _primary.length ? "more" : _primary[i].key),
            ),
          ),
          Expanded(
            child: AnimatedScreenSwitcher(
              screenKey: _tab,
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) => [
                  SliverToBoxAdapter(child: _quickActions()),
                ],
                body: _body(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case "profile":
        return ProfileTab(
          clientId: widget.clientId,
          onGoToIntake: _goToIntakeForm,
          onRequestProgram: (kind) {
            ref.read(programDraftRequestProvider.notifier).ask(widget.clientId, kind);
            _visit("plans", "programs");
          },
        );
      case "intake":
        return IntakeTab(
          // Keyed so that arriving from a different row rebuilds the tab and
          // opens that form, rather than reusing the state of the one already
          // showing.
          key: ValueKey(_intakeKey),
          clientId: widget.clientId,
          initialOpenKey: _intakeKey,
        );
      case "logs":
        return LoggedTab(clientId: widget.clientId);
      case "plans":
        return PlansTab(
          clientId: widget.clientId,
          sub: _plansSub,
          onSubChanged: (s) => _visit("plans", s),
        );
      case "progress":
        return ProgressTab(clientId: widget.clientId);
      case "more":
        return _MorePanel(tabs: _moreTabs, activeKey: null, onSelect: _goTab);
      case "visits":
        return VisitsTab(clientId: widget.clientId);
      case "documents":
        return DocumentsTab(clientId: widget.clientId);
      case "habits":
        return HabitsTab(clientId: widget.clientId);
      case "notes":
        return NotesTab(
          clientId: widget.clientId,
          startComposing: _composeNote,
        );
      case "squad":
        return SquadTab(clientId: widget.clientId);
      case "points":
        return PointsTab(clientId: widget.clientId);
      case "badges":
        return MeritBadgesTab(clientId: widget.clientId);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onMessage,
    required this.onBook,
    required this.onLog,
    required this.onNote,
  });

  final VoidCallback onMessage;
  final VoidCallback onBook;
  final VoidCallback onLog;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundAction(
          icon: LucideIcons.messageSquare,
          label: "Message",
          onTap: onMessage,
        ),
        _RoundAction(
          icon: LucideIcons.calendarPlus,
          label: "Book",
          onTap: onBook,
        ),
        _RoundAction(
          icon: LucideIcons.play,
          label: "Log",
          onTap: onLog,
        ),
        _RoundAction(icon: LucideIcons.plus, label: "Note", onTap: onNote),
      ],
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapHighlight(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        child: Column(
          children: [
            Tooltip(
              message: label,
              child: Container(
                key: Key("quick-action-$label"),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.card,
                  border: Border.all(color: AppColors.line),
                ),
                child: Icon(icon, size: 14, color: AppColors.txt),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: AppColors.mute,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MorePanel extends StatelessWidget {
  const _MorePanel({
    required this.tabs,
    required this.onSelect,
    this.activeKey,
  });

  final List<_TabDef> tabs;
  final String? activeKey;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: const Key("client-more"),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: tabs.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, thickness: 1, indent: 56, color: AppColors.line),
      itemBuilder: (context, index) {
        final tab = tabs[index];
        final active = tab.key == activeKey;
        return TapHighlight(
          onTap: () => onSelect(tab.key),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            child: Row(
              children: [
                Icon(
                  tab.icon,
                  size: 18,
                  color: active ? AppColors.txt : AppColors.mute,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tab.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      color: active ? AppColors.txt : AppColors.txt,
                    ),
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 16, color: AppColors.mute),
              ],
            ),
          ),
        );
      },
    );
  }
}
