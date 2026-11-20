import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/save_error.dart";
import "../../../core/utils/unavailability.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/booking.dart";
import "../../../data/models/trainer.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";

/// All day, from one time through the end of the day, or a start and end
/// on each day of the range.
enum UnavailabilityTimeMode { allDay, fromTime, range }

/// What the server reports after a block is saved.
class UnavailabilitySaveResult {
  const UnavailabilitySaveResult({
    required this.cancelled,
    required this.bookingIds,
    this.alreadyApplied = false,
  });

  final int cancelled;
  final List<String> bookingIds;
  final bool alreadyApplied;

  factory UnavailabilitySaveResult.fromMap(Map<String, dynamic> json) {
    final ids = json["bookingIds"];
    return UnavailabilitySaveResult(
      cancelled: (json["cancelled"] as num?)?.toInt() ?? 0,
      bookingIds: ids is List ? ids.map((e) => e.toString()).toList() : const [],
      alreadyApplied: json["alreadyApplied"] == true,
    );
  }
}

/// The three-way time control. Black, gray, and white only, via [AppColors].
class UnavailabilityTimeToggle extends StatelessWidget {
  const UnavailabilityTimeToggle({super.key, required this.mode, required this.onChanged});

  final UnavailabilityTimeMode mode;
  final ValueChanged<UnavailabilityTimeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final choice in const [
          (UnavailabilityTimeMode.allDay, "All day", Key("unavailability-mode-all-day")),
          (UnavailabilityTimeMode.fromTime, "From a time", Key("unavailability-mode-from")),
          (UnavailabilityTimeMode.range, "Time range", Key("unavailability-mode-range")),
        ]) ...[
          if (choice.$1 != UnavailabilityTimeMode.allDay) const SizedBox(width: 6),
          Expanded(
            child: TapHighlight(
              key: choice.$3,
              onTap: () => onChanged(choice.$1),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                decoration: BoxDecoration(
                  color: mode == choice.$1 ? AppColors.gold : AppColors.bg,
                  border: Border.all(color: mode == choice.$1 ? AppColors.gold : AppColors.line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  choice.$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: mode == choice.$1 ? AppColors.onGold : AppColors.txt,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// "This will cancel N sessions", the sessions, and the save button.
class UnavailabilityPreviewCard extends StatelessWidget {
  const UnavailabilityPreviewCard({
    super.key,
    required this.sessions,
    required this.saving,
    required this.onSave,
  });

  final List<AffectedSession> sessions;
  final bool saving;
  final VoidCallback? onSave;

  String get _title {
    final n = sessions.length;
    if (n == 1) return "This will cancel 1 session";
    return "This will cancel $n sessions";
  }

  String get _button {
    if (saving) return "Saving…";
    final n = sessions.length;
    if (n == 0) return "Save";
    if (n == 1) return "Save and cancel 1 session";
    return "Save and cancel $n sessions";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key("unavailability-preview"),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          if (sessions.isEmpty)
            Text(
              "No sessions are booked in this window.",
              style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35),
            )
          else
            for (final session in sessions)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(session.line, style: TextStyle(fontSize: 12, color: AppColors.txt, height: 1.35)),
              ),
          const SizedBox(height: 10),
          BtnGold(
            key: const Key("unavailability-save"),
            full: true,
            onPressed: saving ? null : onSave,
            child: Text(_button),
          ),
        ],
      ),
    );
  }
}

/// Add, list, and delete time off. Saving a new block is its own action:
/// it is not part of the profile Save button.
class UnavailabilitySection extends StatefulWidget {
  const UnavailabilitySection({
    super.key,
    required this.trainerId,
    required this.entries,
    required this.bookings,
    required this.onChange,
    this.onSave,
    this.onRemove,
    this.onApplied,
  });

  /// Null while a coach is being created. The block is kept on the form
  /// and stored with the new coach. There is nobody to cancel yet.
  final String? trainerId;
  final List<TrainerUnavailability> entries;
  final List<Booking> bookings;
  final ValueChanged<List<TrainerUnavailability>> onChange;
  final Future<UnavailabilitySaveResult> Function(TrainerUnavailability entry)? onSave;
  final Future<void> Function(String entryId)? onRemove;
  final ValueChanged<UnavailabilitySaveResult>? onApplied;

  @override
  State<UnavailabilitySection> createState() => _UnavailabilitySectionState();
}

class _UnavailabilitySectionState extends State<UnavailabilitySection> {
  bool _adding = false;
  bool _saving = false;
  bool _noteEdited = false;
  bool _primingNote = false;
  String? _error;
  String? _start;
  String? _end;
  String? _draftId;
  UnavailabilityTimeMode _mode = UnavailabilityTimeMode.allDay;
  int _fromMin = 9 * 60;
  int _toMin = 17 * 60;
  final _reason = TextEditingController();
  final _clientNote = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    _clientNote.dispose();
    super.dispose();
  }

  void _open() {
    setState(() {
      _adding = true;
      _error = null;
      _draftId = "unavail-${DateTime.now().microsecondsSinceEpoch}";
      _start = null;
      _end = null;
      _mode = UnavailabilityTimeMode.allDay;
      _fromMin = 9 * 60;
      _toMin = 17 * 60;
      _noteEdited = false;
      _reason.clear();
      _clientNote.clear();
    });
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = DateTime.tryParse((isStart ? _start : _end) ?? _start ?? "") ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now.subtract(const Duration(days: 1))) ? now : initial,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    final iso = isoDate(picked);
    setState(() {
      if (isStart) {
        _start = iso;
        if (_end != null && _end!.compareTo(iso) < 0) _end = null;
      } else {
        _end = iso;
      }
      _error = null;
      _primeNote();
    });
  }

  TrainerUnavailability? get _draft {
    final start = _start;
    final id = _draftId;
    if (start == null || id == null) return null;
    final reason = _reason.text.trim();
    return TrainerUnavailability(
      id: id,
      startDate: start,
      endDate: _end ?? start,
      allDay: _mode == UnavailabilityTimeMode.allDay,
      startMin: _mode == UnavailabilityTimeMode.allDay ? null : _fromMin,
      endMin: _mode == UnavailabilityTimeMode.range ? _toMin : null,
      reason: reason.isEmpty ? null : reason,
      note: reason.isEmpty ? null : reason,
      clientNote: _clientNote.text.trim().isEmpty ? null : _clientNote.text.trim(),
    );
  }

  List<AffectedSession> get _affected {
    final draft = _draft;
    final id = widget.trainerId;
    if (draft == null || id == null) return const [];
    return affectedSessionsFor(draft, widget.bookings, trainerId: id);
  }

  @override
  void didUpdateWidget(covariant UnavailabilitySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_adding) _primeNote();
  }

  void _primeNote() {
    if (_affected.isEmpty || _noteEdited) return;
    if (_clientNote.text.trim().isNotEmpty) return;
    _primingNote = true;
    _clientNote.text = kDefaultClientNote;
    _primingNote = false;
  }

  String? _invalid() {
    if (_start == null) return "Choose a start date.";
    if (_end != null && _end!.compareTo(_start!) < 0) return "The end date cannot be before the start date.";
    if (_mode == UnavailabilityTimeMode.range && _toMin <= _fromMin) {
      return "The end time has to be after the start time.";
    }
    if (_reason.text.trim().isEmpty) return "A reason is required.";
    if (_reason.text.trim().length > kUnavailabilityReasonMax) return "Keep the reason short.";
    if (_affected.isNotEmpty && _clientNote.text.trim().isEmpty) {
      return "Write a note for the clients whose sessions will be cancelled.";
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _invalid();
    final draft = _draft;
    if (problem != null || draft == null) {
      setState(() => _error = problem ?? "Choose a start date.");
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      UnavailabilitySaveResult? result;
      if (widget.trainerId != null) {
        final save = widget.onSave;
        if (save == null) throw Exception("Couldn't save that time off.");
        result = await save(draft);
      }
      widget.onChange([...widget.entries, draft]);
      if (result != null) widget.onApplied?.call(result);
      if (!mounted) return;
      setState(() {
        _adding = false;
        _saving = false;
        _draftId = null;
        _start = null;
        _end = null;
        _reason.clear();
        _clientNote.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = saveErrorMessage(e);
      });
    }
  }

  Future<void> _confirmRemove(TrainerUnavailability entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Remove this time off?"),
        content: const Text(
          "Clients will be able to book these times again. Sessions that were already cancelled stay cancelled.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Keep")),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text("Remove")),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _error = null);
    try {
      if (widget.trainerId != null && widget.onRemove != null) {
        await widget.onRemove!(entry.id);
      }
      widget.onChange(widget.entries.where((e) => e.id != entry.id).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = saveErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.entries]..sort((a, b) => a.startDate.compareTo(b.startDate));
    final affected = _adding ? _affected : const <AffectedSession>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "UNAVAILABILITY",
          style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w700, letterSpacing: 0.5),
        ),
        const SizedBox(height: 6),
        Text(
          "Block off time you won't be working. Clients can't book those times. If anyone already has a session in the window, saving cancels it and puts the session back on their plan.",
          style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
        ),
        const SizedBox(height: 10),
        if (sorted.isEmpty && !_adding)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text("No time off scheduled.", style: TextStyle(fontSize: 12, color: AppColors.mute, fontStyle: FontStyle.italic)),
          ),
        for (final e in sorted)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: AppColors.bg,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.startDate == e.endDate ? niceDate(e.startDate) : "${niceDate(e.startDate)} – ${niceDate(e.endDate)}",
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          [
                            unavailabilityStaffTime(e),
                            if (e.displayReason.isNotEmpty) e.displayReason,
                          ].join(" · "),
                          style: TextStyle(fontSize: 11, color: AppColors.mute),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _confirmRemove(e),
                  icon: Icon(LucideIcons.trash2, size: 14, color: AppColors.danger),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
        if (_adding)
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
                Row(
                  children: [
                    Expanded(child: _dateBox(label: "Start date", value: _start, placeholder: "Select date", onTap: () => _pickDate(isStart: true))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _dateBox(
                        label: "End date",
                        value: _end,
                        placeholder: "One day",
                        onTap: _start == null ? null : () => _pickDate(isStart: false),
                      ),
                    ),
                  ],
                ),
                if (_end != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _end = null),
                      style: TextButton.styleFrom(foregroundColor: AppColors.mute, visualDensity: VisualDensity.compact),
                      child: const Text("Clear end date", style: TextStyle(fontSize: 12)),
                    ),
                  ),
                const SizedBox(height: 8),
                UnavailabilityTimeToggle(
                  mode: _mode,
                  onChanged: (mode) => setState(() {
                    _mode = mode;
                    _primeNote();
                  }),
                ),
                if (_mode == UnavailabilityTimeMode.fromTime) ...[
                  const SizedBox(height: 8),
                  FieldLabeled(
                    label: "From",
                    child: TimeField(minutes: _fromMin, onChanged: (v) => setState(() => _fromMin = v)),
                  ),
                ],
                if (_mode == UnavailabilityTimeMode.range) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: FieldLabeled(label: "Start", child: TimeField(minutes: _fromMin, onChanged: (v) => setState(() => _fromMin = v)))),
                      const SizedBox(width: 8),
                      Expanded(child: FieldLabeled(label: "End", child: TimeField(minutes: _toMin, onChanged: (v) => setState(() => _toMin = v)))),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                FieldLabeled(
                  label: "Reason",
                  child: AppField(
                    controller: _reason,
                    placeholder: "Shown to clients, e.g. Vacation",
                    maxLength: kUnavailabilityReasonMax,
                    onChanged: (_) {
                      setState(_primeNote);
                    },
                  ),
                ),
                if (affected.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  FieldLabeled(
                    label: "Note to clients with sessions",
                    child: AppField(
                      controller: _clientNote,
                      placeholder: "They'll get this in chat",
                      maxLength: kUnavailabilityNoteMax,
                      minLines: 2,
                      maxLines: 4,
                      onChanged: (_) {
                        if (_primingNote) return;
                        setState(() => _noteEdited = true);
                      },
                    ),
                  ),
                ],
                if (_start != null) ...[
                  const SizedBox(height: 10),
                  UnavailabilityPreviewCard(
                    sessions: affected,
                    saving: _saving,
                    onSave: _saving ? null : _save,
                  ),
                ],
                if (widget.trainerId == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      "This is stored when you add the coach.",
                      style: TextStyle(fontSize: 11, color: AppColors.mute),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
                  ),
                const SizedBox(height: 8),
                BtnGhost(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _adding = false;
                            _error = null;
                          }),
                  child: const Text("Cancel"),
                ),
              ],
            ),
          )
        else
          TextButton.icon(
            onPressed: _open,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.gold,
              side: BorderSide(color: AppColors.goldDim),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            ),
            icon: const Icon(LucideIcons.plus, size: 13),
            label: const Text("Add Unavailability", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        if (_error != null && !_adding)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _dateBox({
    required String label,
    required String? value,
    required String placeholder,
    required VoidCallback? onTap,
  }) {
    return FieldLabeled(
      label: label,
      child: TapHighlight(
        onTap: onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.card,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line)),
          ),
          child: Text(
            value == null ? placeholder : niceDate(value),
            style: TextStyle(fontSize: 13, color: value == null ? AppColors.mute : AppColors.txt),
          ),
        ),
      ),
    );
  }
}

/// Wires the section to the live bookings and the server save.
class UnavailabilityHost extends ConsumerWidget {
  const UnavailabilityHost({
    super.key,
    required this.trainerId,
    required this.entries,
    required this.onChange,
  });

  final String? trainerId;
  final List<TrainerUnavailability> entries;
  final ValueChanged<List<TrainerUnavailability>> onChange;

  void _remember(WidgetRef ref, List<TrainerUnavailability> next) {
    onChange(next);
    final id = trainerId;
    if (id == null) return;
    final matches = ref.read(trainersProvider).where((t) => t.id == id);
    if (matches.isEmpty) return;
    ref.read(trainersProvider.notifier).upsert(matches.first.copyWith(unavailability: next));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = trainerId;
    return UnavailabilitySection(
      trainerId: id,
      entries: entries,
      bookings: ref.watch(allBookingsProvider),
      onChange: (next) => _remember(ref, next),
      onSave: id == null
          ? null
          : (entry) async {
              final raw = await SupabaseService.saveCoachUnavailability(trainerId: id, entry: entry);
              return UnavailabilitySaveResult.fromMap(raw);
            },
      onRemove: id == null
          ? null
          : (entryId) => SupabaseService.removeCoachUnavailability(trainerId: id, entryId: entryId),
      onApplied: (result) {
        for (final bookingId in result.bookingIds) {
          ref.read(allBookingsProvider.notifier).cancelBooking(bookingId);
          ref.read(clientBookingsProvider.notifier).cancelBooking(bookingId);
        }
      },
    );
  }
}
