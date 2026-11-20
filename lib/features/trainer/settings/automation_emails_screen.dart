import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/platform_settings_provider.dart";

/// One automation email as stored in `email_templates`.
class EmailTemplateRow {
  EmailTemplateRow.fromJson(Map<String, dynamic> j)
      : key = j["key"] as String,
        name = (j["name"] as String?) ?? "",
        trigger = (j["trigger"] as String?) ?? "",
        enabled = j["enabled"] as bool? ?? true,
        subject = (j["subject"] as String?) ?? "",
        body = (j["body"] as String?) ?? "",
        variables = _vars(j["variables"]),
        blockVariables = _vars(j["block_variables"]),
        editedAt = DateTime.tryParse((j["edited_at"] as String?) ?? "")?.toLocal();

  final String key;
  final String name;
  final String trigger;
  final bool enabled;
  final String subject;
  final String body;

  /// (key, label) valid anywhere in this email.
  final List<(String, String)> variables;

  /// (key, label) valid only inside the {{#each sessions}} block.
  final List<(String, String)> blockVariables;
  final DateTime? editedAt;

  bool get hasBlock => blockVariables.isNotEmpty;

  static List<(String, String)> _vars(Object? raw) => [
        for (final v in (raw as List? ?? const []))
          if (v is Map) ((v["key"] ?? "").toString(), (v["label"] ?? v["key"] ?? "").toString()),
      ];
}

final _anyToken = RegExp(r"\{\{([^}]*)\}\}");
final _blockPattern = RegExp(r"\{\{#each sessions\}\}([\s\S]*?)\{\{/each\}\}");

/// Same rule the database enforces on save. Returns a message naming the
/// offending token, or null when the template is valid.
String? validateTemplate(EmailTemplateRow t, String subject, String body) {
  final allowed = {for (final v in t.variables) v.$1};
  final blockOnly = {for (final v in t.blockVariables) v.$1};

  for (final m in _anyToken.allMatches(subject)) {
    final tok = m.group(1)!.trim();
    if (!allowed.contains(tok)) return "Unknown variable {{$tok}} in the subject line.";
  }

  final inside = StringBuffer();
  for (final m in _blockPattern.allMatches(body)) {
    inside.writeln(m.group(1));
  }
  final outside = body.replaceAll(_blockPattern, "");
  for (final m in _anyToken.allMatches(outside)) {
    final tok = m.group(1)!.trim();
    if (!allowed.contains(tok)) {
      return blockOnly.contains(tok)
          ? "{{$tok}} can only be used inside the {{#each sessions}} block."
          : "Unknown variable {{$tok}}.";
    }
  }
  for (final m in _anyToken.allMatches(inside.toString())) {
    final tok = m.group(1)!.trim();
    if (!allowed.contains(tok) && !blockOnly.contains(tok)) return "Unknown variable {{$tok}} in the sessions block.";
  }
  return null;
}

/// Customize Platform → Automation Emails (owner). Lists every automation email
/// in the system (rows of `email_templates`, so new ones appear automatically)
/// and opens one in an editor.
class AutomationEmailsScreen extends ConsumerStatefulWidget {
  const AutomationEmailsScreen({super.key});

  @override
  ConsumerState<AutomationEmailsScreen> createState() => _AutomationEmailsScreenState();
}

class _AutomationEmailsScreenState extends ConsumerState<AutomationEmailsScreen> {
  List<EmailTemplateRow> _rows = [];
  bool _loading = true;
  String? _error;
  EmailTemplateRow? _editing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.loadEmailTemplates();
      if (!mounted) return;
      setState(() {
        _rows = rows.map(EmailTemplateRow.fromJson).toList();
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = "Couldn't load the automation emails — check your connection.";
          _loading = false;
        });
      }
    }
  }

  static const _months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  String _date(DateTime d) => "${_months[d.month - 1]} ${d.day}, ${d.year}";

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    if (editing != null) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() => _editing = null),
        child: _TemplateEditor(
          key: ValueKey(editing.key),
          row: editing,
          business: ref.watch(platformSettingsProvider).businessName,
          onClose: () => setState(() => _editing = null),
          onSaved: () async {
            await _load();
            if (mounted) setState(() => _editing = null);
          },
        ),
      );
    }
    if (_loading) return Center(child: CircularProgressIndicator(color: AppColors.gold));
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const SectionLabel("Automation Emails"),
        const SizedBox(height: 8),
        const HintBox(
          text: "Every automatic email the system sends. Tap one to edit its subject and wording, or switch it off. "
              "Changes take effect on the next send.",
        ),
        const SizedBox(height: 14),
        if (_error != null) HintBox(text: _error!),
        for (final r in _rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppCard(
              onTap: () => setState(() => _editing = r),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.mail, size: 18, color: AppColors.gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(r.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                            Tag(text: r.enabled ? "On" : "Off"),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text("Trigger: ${r.trigger}", style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35)),
                        const SizedBox(height: 3),
                        Text(
                          r.editedAt == null ? "Last edited: original wording" : "Last edited: ${_date(r.editedAt!)}",
                          style: TextStyle(fontSize: 11.5, color: AppColors.mute),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(LucideIcons.chevronRight, size: 15, color: AppColors.mute),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({
    super.key,
    required this.row,
    required this.business,
    required this.onClose,
    required this.onSaved,
  });

  final EmailTemplateRow row;
  final String business;
  final VoidCallback onClose;
  final Future<void> Function() onSaved;

  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final _subject = TextEditingController(text: widget.row.subject);
  late final _body = TextEditingController(text: widget.row.body);
  final _subjectFocus = FocusNode();
  final _bodyFocus = FocusNode();
  late bool _enabled = widget.row.enabled;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subject.addListener(_changed);
    _body.addListener(_changed);
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _subjectFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  /// Inserts at the cursor of whichever field was last focused (the body by
  /// default).
  void _insert(String text, {required bool subjectOnly}) {
    final useSubject = subjectOnly || _subjectFocus.hasFocus;
    final c = useSubject ? _subject : _body;
    final sel = c.selection;
    final at = sel.start < 0 ? c.text.length : sel.start;
    final end = sel.end < 0 ? at : sel.end;
    c.value = TextEditingValue(
      text: c.text.replaceRange(at, end, text),
      selection: TextSelection.collapsed(offset: at + text.length),
    );
  }

  Future<void> _save() async {
    final problem = validateTemplate(widget.row, _subject.text, _body.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_subject.text.trim().isEmpty || _body.text.trim().isEmpty) {
      setState(() => _error = "The subject and the body can't be empty.");
      return;
    }
    setState(() => _saving = true);
    try {
      await SupabaseService.saveEmailTemplate(
        widget.row.key,
        subject: _subject.text.trim(),
        body: _body.text.trimRight(),
        enabled: _enabled,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Saved. It applies from the next send.")));
      await widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      var msg = e.toString();
      final m = RegExp(r"message: ([^,}]+)").firstMatch(msg);
      if (m != null) msg = m.group(1)!;
      setState(() {
        _saving = false;
        _error = msg.replaceFirst("Exception: ", "");
      });
    }
  }

  // ── live preview ──────────────────────────────────────────────────────────
  Map<String, String> get _sample {
    final fee = widget.row.key == "no_show" ? "\$25" : "\$15";
    return {
      "client_first_name": "Alex",
      "business_name": widget.business,
      "session_count": "2 sessions",
      "session_date": "Monday, March 3, 2026",
      "session_time": "6:00 AM",
      "coach_name": "Coach Chris",
      "session_type": "One-on-one",
      "session_location": "ONE Fitness Studio",
      "charge_amount": fee,
      "payment_note": "A $fee fee has been charged to the payment method on file.",
    };
  }

  String _fill(String text, Map<String, String> vars) =>
      text.replaceAllMapped(RegExp(r"\{\{\s*([a-zA-Z_]+)\s*\}\}"), (m) => vars[m.group(1)] ?? m.group(0)!);

  String _renderBody() {
    final vars = _sample;
    final body = _body.text;
    final m = _blockPattern.firstMatch(body);
    if (m == null) return _fill(body, vars);
    final second = {...vars, "session_date": "Wednesday, March 5, 2026", "session_time": "6:00 PM", "coach_name": "Coach Dana"};
    final block = [vars, second].map((v) => _fill(_fill(m.group(1)!.trim(), v), vars)).join("\n\n");
    return _fill(body.substring(0, m.start), vars) + block + _fill(body.substring(m.end), vars);
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final blockVars = row.blockVariables;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: widget.onClose, title: row.name),
          const SizedBox(height: 6),
          Text("Trigger: ${row.trigger}", style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.35)),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text("Send this email", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            subtitle: Text(
              _enabled ? "On — clients receive it automatically." : "Off — nothing is sent for this event.",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Expanded(child: SectionLabel("Subject")),
              PopupMenuButton<String>(
                tooltip: "Insert a variable into the subject",
                onSelected: (k) => _insert("{{$k}}", subjectOnly: true),
                itemBuilder: (_) => [
                  for (final v in row.variables) PopupMenuItem(value: v.$1, child: Text(v.$2)),
                ],
                child: _pickerLabel(),
              ),
            ],
          ),
          TextField(
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            controller: _subject,
            focusNode: _subjectFocus,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: SectionLabel("Body")),
              PopupMenuButton<String>(
                tooltip: "Insert a variable into the body",
                onSelected: (k) {
                  if (k == "#block") {
                    _insert("{{#each sessions}}\n${blockVars.map((v) => "{{${v.$1}}}").join("\n")}\n{{/each}}", subjectOnly: false);
                  } else {
                    _insert("{{$k}}", subjectOnly: false);
                  }
                },
                itemBuilder: (_) => [
                  for (final v in row.variables) PopupMenuItem(value: v.$1, child: Text(v.$2)),
                  if (row.hasBlock) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: "#block", child: Text("Repeating sessions block", style: TextStyle(fontWeight: FontWeight.w700))),
                    for (final v in blockVars) PopupMenuItem(value: v.$1, child: Text("   in block: ${v.$2}")),
                  ],
                ],
                child: _pickerLabel(),
              ),
            ],
          ),
          TextField(
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            controller: _body,
            focusNode: _bodyFocus,
            minLines: 12,
            maxLines: 30,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontSize: 13.5, height: 1.4),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
          if (row.hasBlock)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                "Lines between {{#each sessions}} and {{/each}} repeat once per session. "
                "Session variables only work inside that block.",
                style: TextStyle(fontSize: 11.5, color: AppColors.mute, height: 1.4),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: TextStyle(fontSize: 13, color: AppColors.danger, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 18),
          const SectionLabel("Preview (sample data)"),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fill(_subject.text, _sample),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                const Divider(height: 18),
                Text(_renderBody(), style: const TextStyle(fontSize: 13.5, height: 1.45)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          BtnGold(
            onPressed: _saving ? null : _save,
            full: true,
            child: _saving
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(AppColors.onGold)))
                : const Text("Save"),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _pickerLabel() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.atSign, size: 14, color: AppColors.gold),
          const SizedBox(width: 3),
          Text("Insert variable", style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w700)),
        ],
      );
}
