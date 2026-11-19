import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/coach_application_files.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/trainer_providers.dart";

String _kindLabel(String kind) => switch (kind) {
      "freeze_membership" => "Freeze membership",
      "unfreeze_membership" => "End a freeze",
      "restrict_client" => "Restrict booking",
      "lift_restriction" => "Lift a restriction",
      "extra_free_session" => "Extra free session",
      "adjust_balance" => "Change a balance",
      "delete_client" => "Delete a client",
      _ => kind,
    };

String _when(Map<String, dynamic> row) {
  final from = row["payload"] is Map ? (row["payload"] as Map)["from"] : null;
  final to = row["payload"] is Map ? (row["payload"] as Map)["to"] : null;
  final reason = (row["reason"] as String?)?.trim();
  final bits = <String>[
    if (from != null && to != null) "$from to $to",
    if (reason != null && reason.isNotEmpty) reason,
  ];
  return bits.join(" · ");
}

/// Coaches see the requests they sent. The owner approves or denies them,
/// and reviews coach applications in the same place.
class RequestsScreen extends ConsumerStatefulWidget {
  const RequestsScreen({super.key});

  @override
  ConsumerState<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends ConsumerState<RequestsScreen> {
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _applications = [];
  bool _loading = true;
  String? _error;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (ref.read(trainerAuthProvider) == "owner") {
        try {
          await SupabaseService.applyDueRequests();
        } catch (_) {
          // A freeze that is not due yet is not an error worth blocking the list.
        }
      }
      final requests = await SupabaseService.loadCoachRequests();
      List<Map<String, dynamic>> applications = [];
      if (ref.read(trainerAuthProvider) == "owner") {
        applications = await SupabaseService.loadCoachApplications();
      }
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _applications = applications;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load requests. If this is a new install, the database update has to be applied first.";
      });
    }
  }

  Future<void> _decide(String id, bool approve) async {
    setState(() => _busyId = id);
    try {
      await SupabaseService.decideCoachRequest(id: id, approve: approve);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst("Exception: ", ""))),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _decideApplication(String id, bool approve) async {
    setState(() => _busyId = id);
    try {
      final res = await SupabaseService.decideCoachApplication(id: id, approve: approve);
      if (!mounted) return;
      final sent = res["codeSent"] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(!approve
              ? "Application denied. They were emailed."
              : sent
                  ? "Approved. The coach code was emailed to them."
                  : "Approved. The current code was already used, so generate a new one and send it."),
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst("Exception: ", ""))),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = ref.watch(trainerAuthProvider) == "owner";
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (_error != null) HintBox(text: _error!),
          if (isOwner) ...[
            const SectionLabel("Coach applications"),
            const SizedBox(height: 6),
            if (_applications.isEmpty) const HintBox(text: "No applications yet."),
            for (final app in _applications) _ApplicationCard(
              app: app,
              busy: _busyId == app["id"],
              onApprove: () => _decideApplication(app["id"].toString(), true),
              onDeny: () => _decideApplication(app["id"].toString(), false),
            ),
            const SizedBox(height: 18),
          ],
          SectionLabel(isOwner ? "Coach requests" : "Your requests"),
          const SizedBox(height: 6),
          HintBox(
            text: isOwner
                ? "Nothing here changes a client until you approve it. A freeze still waits 48 hours after you approve it, and not before the from-date."
                : "Freeze, restrict, a second free session, a balance change, and deleting an account all wait here until the owner decides. You can also start them from a client's profile or from Book session.",
          ),
          const SizedBox(height: 10),
          if (_requests.isEmpty) const HintBox(text: "Nothing waiting."),
          for (final row in _requests)
            _RequestCard(
              row: row,
              isOwner: isOwner,
              busy: _busyId == row["id"],
              onApprove: () => _decide(row["id"].toString(), true),
              onDeny: () => _decide(row["id"].toString(), false),
            ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.row,
    required this.isOwner,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
  });

  final Map<String, dynamic> row;
  final bool isOwner;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final status = row["status"]?.toString() ?? "pending";
    final pending = status == "pending";
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_kindLabel(row["kind"]?.toString() ?? ""), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            const SizedBox(height: 4),
            Text(
              "${status[0].toUpperCase()}${status.substring(1)}"
              "${_when(row).isEmpty ? "" : " · ${_when(row)}"}",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
            if (isOwner && pending) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: BtnGold(onPressed: busy ? null : onApprove, child: Text(busy ? "Working…" : "Approve"))),
                  const SizedBox(width: 8),
                  Expanded(child: BtnGhost(onPressed: busy ? null : onDeny, child: const Text("Deny"))),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

List<String> _applicationLines(Map<String, dynamic> app) {
  final docs = <({String? kind, String name})>[];
  final rawDocs = app["document_paths"];
  if (rawDocs is List) {
    for (final item in rawDocs) {
      if (item is! Map) continue;
      docs.add((kind: item["kind"]?.toString(), name: item["name"]?.toString() ?? "File"));
    }
  }
  int count(dynamic raw) => raw is List ? raw.length : 0;
  return applicationReviewLines(
    documents: docs,
    beforeAfterPairs: count(app["before_after_paths"]),
    locationPhotoCount: count(app["location_photo_paths"]),
  );
}

class _ApplicationCard extends StatefulWidget {
  const _ApplicationCard({
    required this.app,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
  });

  final Map<String, dynamic> app;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  State<_ApplicationCard> createState() => _ApplicationCardState();
}

class _ApplicationCardState extends State<_ApplicationCard> {
  List<({String? before, String? after})> _pairs = const [];

  @override
  void initState() {
    super.initState();
    _loadPairs();
  }

  Future<void> _loadPairs() async {
    final raw = widget.app["before_after_paths"];
    if (raw is! List || raw.isEmpty) return;
    final next = <({String? before, String? after})>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final beforePath = item["beforePath"]?.toString();
      final afterPath = item["afterPath"]?.toString();
      if (beforePath == null || afterPath == null || beforePath.isEmpty || afterPath.isEmpty) continue;
      try {
        next.add((
          before: await SupabaseService.signedApplicationFile(beforePath),
          after: await SupabaseService.signedApplicationFile(afterPath),
        ));
      } catch (_) {
        next.add((before: null, after: null));
      }
    }
    if (mounted) setState(() => _pairs = next);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final status = app["status"]?.toString() ?? "pending";
    final pending = status == "pending";
    final name = "${app["first_name"] ?? ""} ${app["last_name"] ?? ""}".trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name.isEmpty ? "Coach application" : name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            const SizedBox(height: 4),
            Text(
              "${app["email"] ?? ""} · ${app["location_name"] ?? ""} · $status",
              style: TextStyle(fontSize: 12, color: AppColors.mute),
            ),
            if ((app["pitch"] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(app["pitch"].toString(), style: const TextStyle(fontSize: 13, height: 1.4)),
            ],
            const SizedBox(height: 8),
            for (final line in _applicationLines(app))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(line, style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.txt)),
              ),
            for (var i = 0; i < _pairs.length; i++) ...[
              const SizedBox(height: 8),
              Text("Before and after pair ${i + 1}", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.txt)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: _ReviewHalf(label: "Before", url: _pairs[i].before)),
                  const SizedBox(width: 8),
                  Expanded(child: _ReviewHalf(label: "After", url: _pairs[i].after)),
                ],
              ),
            ],
            if (pending) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: BtnGold(onPressed: widget.busy ? null : widget.onApprove, child: Text(widget.busy ? "Working…" : "Approve"))),
                  const SizedBox(width: 8),
                  Expanded(child: BtnGhost(onPressed: widget.busy ? null : widget.onDeny, child: const Text("Deny"))),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewHalf extends StatelessWidget {
  const _ReviewHalf({required this.label, required this.url});

  final String label;
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 3 / 4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.bg,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: url == null
                ? Center(child: Text(label, style: TextStyle(color: AppColors.mute, fontSize: 12)))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(url!, fit: BoxFit.cover),
                  ),
          ),
        ),
      ],
    );
  }
}
