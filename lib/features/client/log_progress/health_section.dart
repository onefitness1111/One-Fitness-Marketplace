import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/health/health_stats.dart";
import "../../../core/health/health_sync.dart";
import "../../../core/health/wearable_reader.dart";
import "../../../core/platform/web_fallback.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/coach_names.dart";
import "../../../core/widgets/app_buttons.dart";
import "../../../core/widgets/app_card.dart";
import "../../../data/providers/client_providers.dart";
import "connect_device_sheet.dart";
import "health_panel.dart";

/// Overview on Log Progress. On-device numbers stay on screen even when the
/// health tables are not in the database yet. Sharing stays off until the
/// client turns it on and the save succeeds.
class HealthSection extends ConsumerStatefulWidget {
  const HealthSection({
    super.key,
    this.platform,
    this.read,
    this.save,
    this.loadShare,
    this.accountId,
    this.resolveAccount = true,
  });

  final HealthPlatform? platform;
  final Future<HealthReading?> Function()? read;
  final Future<HealthPersistOutcome> Function(HealthReading reading, bool share)? save;
  final Future<bool?> Function(String accountId)? loadShare;

  /// Used when [resolveAccount] is false, so tests can save without a session.
  final String? accountId;
  final bool resolveAccount;

  @override
  ConsumerState<HealthSection> createState() => _HealthSectionState();
}

class _HealthSectionState extends ConsumerState<HealthSection> {
  HealthReading? _reading;
  bool _share = false;
  bool _busy = false;
  String? _note;

  HealthPlatform get _platform => widget.platform ?? WearableReader.platform;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  String? _account() {
    if (!widget.resolveAccount) return widget.accountId;
    try {
      return SupabaseService.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  String _coachName() {
    final info = ref.read(clientInfoProvider);
    for (final trainer in ref.read(trainersProvider)) {
      if (trainer.id == info.primaryTrainerId) return trainer.displayTitle;
    }
    return coachPublicName();
  }

  double? _weightGoal() {
    final goal = ref.read(clientRecordProvider).progressGoal;
    if (goal == null || goal.kind != "weight") return null;
    return goal.target;
  }

  Future<void> _restore() async {
    if (_platform == HealthPlatform.other && widget.read == null) return;
    final account = _account();
    if (account != null && account.isNotEmpty) {
      final savedShare = widget.loadShare != null ? await widget.loadShare!(account) : await HealthSync().loadShare(account);
      if (!mounted) return;
      if (savedShare != null) setState(() => _share = savedShare);
    }
    if (widget.read != null) return;
    if (!WearableReader.supported) return;
    try {
      final reader = WearableReader();
      final granted = await reader.hasReadAccess();
      if (granted != true || !mounted) return;
      final reading = await reader.read();
      if (!mounted) return;
      await _keep(reading, share: _share);
    } catch (_) {}
  }

  Future<void> _connect() async {
    if (kIsWeb || (_platform == HealthPlatform.other && widget.read == null)) {
      setState(() => _note = kIsWeb
          ? kAvailableInMobileApp
          : "Connect Apple Health on iPhone, or Health Connect on Android.");
      return;
    }
    final choice = await showConnectDeviceSheet(context, platform: _platform);
    if (choice == null || !mounted) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      HealthReading? reading;
      if (widget.read != null) {
        reading = await widget.read!();
      } else {
        final attempt = await WearableReader().connectAndRead();
        if (!mounted) return;
        if (attempt.needsInstall) {
          setState(() => _note = "Install Health Connect, then come back and connect.");
          return;
        }
        if (!attempt.granted || attempt.reading == null) {
          setState(() => _note = "Access wasn't allowed. You can turn it on in the phone's health settings.");
          return;
        }
        reading = attempt.reading;
      }
      if (reading == null || !mounted) return;
      await _keep(reading, share: _share);
    } catch (_) {
      if (mounted) setState(() => _note = "Couldn't read health data. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _keep(HealthReading reading, {required bool share}) async {
    final outcome = await _save(reading, share);
    if (!mounted) return;
    setState(() {
      _reading = reading;
      _share = outcome.saved ? share : false;
      _note = reading.hasAny ? healthSaveNote(outcome: outcome, coachName: _coachName()) : "Connected. Nothing from the last 90 days yet.";
    });
  }

  Future<HealthPersistOutcome> _save(HealthReading reading, bool share) {
    if (widget.save != null) return widget.save!(reading, share);
    return HealthSync().save(accountId: _account(), reading: reading, shareWithCoach: share);
  }

  Future<void> _toggle(bool next) async {
    final reading = _reading;
    if (reading == null) return;
    final previous = _share;
    setState(() => _share = next);
    final outcome = await _save(reading, next);
    if (!mounted) return;
    setState(() {
      _share = outcome.saved ? next : previous;
      _note = healthSaveNote(outcome: outcome, coachName: _coachName());
    });
  }

  @override
  Widget build(BuildContext context) {
    final reading = _reading;
    final coach = _coachName();
    final connected = reading != null;
    return SingleChildScrollView(
      key: const Key("health-section"),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Connected devices", style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  connected
                      ? syncedLine(reading.syncedAt, DateTime.now(), reading.sourceLabel, reading.deviceNames)
                      : kIsWeb
                          ? kAvailableInMobileApp
                          : "Nothing connected yet. Read only.",
                  style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.mute),
                ),
                const SizedBox(height: 8),
                BtnGhost(
                  key: const Key("connect-device"),
                  onPressed: _busy ? null : _connect,
                  full: true,
                  child: Text(_busy ? "Asking…" : connected ? "Refresh" : "Connect a device"),
                ),
              ],
            ),
          ),
          if (reading != null && reading.hasAny) ...[
            HealthFlagList(flags: healthFlags(days: reading.days, today: DateTime.now(), weightGoalLb: _weightGoal())),
            HealthTodayGrid(reading: reading, now: DateTime.now()),
            HealthTrendsBlock(days: reading.days, now: DateTime.now(), weightGoalLb: _weightGoal()),
            HealthWorkoutList(workouts: reading.workouts, now: DateTime.now()),
          ],
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Share health stats with my coach", style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(shareHealthCaption(coach), style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.mute)),
                    ],
                  ),
                ),
                Switch(
                  key: const Key("share-health-toggle"),
                  value: _share,
                  onChanged: connected && !_busy ? _toggle : null,
                  thumbColor: WidgetStateProperty.all(AppColors.txt),
                  trackColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) return AppColors.line;
                    return AppColors.bg;
                  }),
                ),
              ],
            ),
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_note!, style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.mute)),
            ),
        ],
      ),
    );
  }
}
