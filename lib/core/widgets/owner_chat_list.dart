import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "../chat/owner_inbox.dart";
import "../chat/unread_dot.dart";
import "../theme/app_colors.dart";
import "widgets.dart";

/// The owner's Chat list: every thread, a coach filter, and a client search.
class OwnerChatList extends StatelessWidget {
  const OwnerChatList({
    super.key,
    required this.rows,
    required this.filters,
    required this.selectedKey,
    required this.onFilter,
    required this.onOpen,
    required this.onNewChat,
    this.onQuery,
    this.query = "",
    this.onNewBroadcast,
    this.emptyText = "No conversations yet.",
    this.now,
  });

  final List<OwnerInboxRow> rows;
  final List<OwnerCoachOption> filters;
  final String selectedKey;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onOpen;
  final VoidCallback onNewChat;
  final ValueChanged<String>? onQuery;
  final String query;
  final VoidCallback? onNewBroadcast;
  final String emptyText;

  /// Clock for the row timestamps. Tests pass a fixed instant.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _FilterPills(
            filters: filters,
            selectedKey: selectedKey,
            onFilter: onFilter,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: _ClientSearch(initial: query, onQuery: onQuery),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      emptyText,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: AppColors.mute, height: 1.5),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.line, indent: 70),
                  itemBuilder: (context, i) => _Row(row: rows[i], onOpen: onOpen, now: now ?? DateTime.now()),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BtnGold(
                full: true,
                onPressed: onNewChat,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.penSquare, size: 15),
                    SizedBox(width: 8),
                    Text("New message"),
                  ],
                ),
              ),
              if (onNewBroadcast != null) ...[
                const SizedBox(height: 8),
                BtnGhost(
                  full: true,
                  onPressed: onNewBroadcast,
                  child: const Text("New broadcast"),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ClientSearch extends StatefulWidget {
  const _ClientSearch({required this.initial, required this.onQuery});

  final String initial;
  final ValueChanged<String>? onQuery;

  @override
  State<_ClientSearch> createState() => _ClientSearchState();
}

class _ClientSearchState extends State<_ClientSearch> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key("owner-chat-search"),
      controller: _controller,
      onChanged: widget.onQuery,
      style: TextStyle(color: AppColors.txt, fontSize: 14),
      decoration: InputDecoration(
        hintText: "Search by client name",
        hintStyle: TextStyle(color: AppColors.mute, fontSize: 14),
        prefixIcon: Icon(LucideIcons.search, size: 16, color: AppColors.mute),
        filled: true,
        fillColor: AppColors.card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.gold),
        ),
      ),
    );
  }
}

class _FilterPills extends StatelessWidget {
  const _FilterPills({
    required this.filters,
    required this.selectedKey,
    required this.onFilter,
  });

  final List<OwnerCoachOption> filters;
  final String selectedKey;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key("owner-coach-filter"),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in filters)
          _Pill(
            label: option.label,
            selected: option.key == selectedKey,
            onTap: () => onFilter(option.key),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapHighlight(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.gold : AppColors.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? AppColors.gold : AppColors.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? AppColors.onGold : AppColors.mute,
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.onOpen, required this.now});

  final OwnerInboxRow row;
  final ValueChanged<String> onOpen;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final label = row.team ? kTeamChatLabel : row.coachLabel;
    return TapHighlight(
      onTap: () => onOpen(row.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Avatar(src: row.photo, name: row.title, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: row.unread ? FontWeight.w800 : FontWeight.w600,
                            color: AppColors.txt,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _stamp(row.at, now),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: row.unread ? FontWeight.w700 : FontWeight.w400,
                          color: row.unread ? AppColors.gold : AppColors.mute,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.gold),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.outgoing ? "You: ${row.preview}" : row.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: row.unread ? AppColors.txt : AppColors.mute,
                            fontWeight: row.unread ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (row.unread) ...[
                        const SizedBox(width: 8),
                        const UnreadDot(),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _stamp(DateTime at, DateTime now) {
  final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
  if (sameDay) {
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return "$h:${at.minute.toString().padLeft(2, "0")} ${at.hour < 12 ? "AM" : "PM"}";
  }
  final diff = now.difference(at).inDays;
  if (diff < 7) {
    const names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    return names[at.weekday - 1];
  }
  return "${at.month}/${at.day}/${at.year % 100}";
}
