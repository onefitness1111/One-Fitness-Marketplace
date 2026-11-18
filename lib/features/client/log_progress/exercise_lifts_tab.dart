import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/squad_chat_message.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/supabase_bootstrap_provider.dart";

// Rebuilt on each read rather than held in a `final`: a lazily-initialised
// field would capture whichever palette happened to be active the first
// time it was touched and keep those colours after a theme switch.
List<Color> get _chartColors => [AppColors.statusGreen, AppColors.gold, Color(0xFF64B5F6), Color(0xFFFF7043), Color(0xFFCE93D8), Color(0xFF80DEEA)];

/// Mirrors LogProgressPage.jsx's "Lifts" tab — pick up to 6 exercises from
/// workout history, chart their heaviest completed set over time.
class ExerciseLiftsTab extends ConsumerStatefulWidget {
  const ExerciseLiftsTab({super.key});

  @override
  ConsumerState<ExerciseLiftsTab> createState() => _ExerciseLiftsTabState();
}

class _ExerciseLiftsTabState extends ConsumerState<ExerciseLiftsTab> {
  final List<String> _selected = [];
  bool _sharing = false;

  Future<void> _shareWithSquad(Map<String, List<double?>> seriesByName) async {
    if (_sharing) return;
    final info = ref.read(clientInfoProvider);
    final squad = ref.read(squadsProvider.notifier).squadFor(info.id);
    if (squad == null) return;
    final entry = SquadChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      from: info.id,
      at: stamp(),
      type: "shared_progress",
      shareKind: "exercises",
      payload: {
        "exercises": _selected,
        "series": seriesByName.map((k, v) => MapEntry(k, v.whereType<double>().toList())),
      },
    );
    setState(() => _sharing = true);
    final ok = await mutateSquad(ref, squad, (s) => s.copyWith(chat: [entry, ...s.chat]));
    if (!mounted) return;
    setState(() => _sharing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? "Shared to Squad chat" : "Couldn't share — check your connection and try again.")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientRecordProvider);
    final info = ref.watch(clientInfoProvider);
    final squad = ref.watch(squadsProvider.notifier).squadFor(info.id);

    // name -> [(date, weight)], mirrors LogProgressPage.jsx's exerciseHistory build-up.
    final history = <String, List<(String, double)>>{};
    // Keyed by workout (date + position), not by date alone: two workouts
    // logged on the same day used to collapse into one point, so the chart
    // still said "need more history" after the client had logged two.
    final orderedLogs = [...client.workoutLogs.asMap().entries]
      ..sort((a, b) {
        final c = a.value.date.compareTo(b.value.date);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    for (final entry in orderedLogs) {
      final log = entry.value;
      final logKey = "${log.date}#${entry.key.toString().padLeft(6, "0")}";
      for (final ex in log.exercises) {
        final doneWeights = ex.sets.where((s) => s.completed && (s.completedWeight ?? 0) > 0).map((s) => s.completedWeight!);
        if (doneWeights.isEmpty) continue;
        final maxW = doneWeights.reduce((a, b) => a > b ? a : b);
        history.putIfAbsent(ex.name, () => []).add((logKey, maxW));
      }
    }
    final names = history.keys.toList()..sort();

    final allDates = {for (final n in _selected) ...history[n]!.map((e) => e.$1)}.toList()..sort();
    final canChart = _selected.isNotEmpty && _selected.any((n) => (history[n]?.length ?? 0) >= 2);

    // Four dots at most: the weight they STARTED at, then their last three
    // logged weights. With four or fewer workouts that is simply all of them;
    // from the fifth on, dots 2-4 cycle forward while the first stays put.
    List<(String, double)> dotsFor(String name) {
      final h = history[name] ?? const <(String, double)>[];
      if (h.length <= 4) return h;
      return [h.first, ...h.sublist(h.length - 3)];
    }

    List<double?>? seriesFor(String name) {
      final byDate = {for (final e in history[name] ?? const <(String, double)>[]) e.$1: e.$2};
      return allDates.map((d) => byDate[d]).toList();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("Choose exercises to chart (max 6)"),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: names.map((name) {
              final sel = _selected.contains(name);
              final colorIdx = _selected.indexOf(name);
              final color = sel ? _chartColors[colorIdx % _chartColors.length] : AppColors.mute;
              return InkWell(
                onTap: () => setState(() {
                  if (sel) {
                    _selected.remove(name);
                  } else if (_selected.length < 6) {
                    _selected.add(name);
                  }
                }),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: sel ? color.withValues(alpha: 0.13) : Colors.transparent,
                    border: Border.all(color: sel ? color : AppColors.line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(name, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          if (names.isEmpty)
            const HintBox(text: "Log some workouts first — exercise charts will appear here automatically.")
          else if (_selected.isNotEmpty && !canChart)
            const HintBox(text: "Need more workout history to chart.")
          else if (canChart)
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _selected.length; i++) ...[
                    if (i > 0) const SizedBox(height: 18),
                    Text(
                      _selected[i],
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _chartColors[i % _chartColors.length]),
                    ),
                    const SizedBox(height: 6),
                    if (dotsFor(_selected[i]).length < 2)
                      Text("Log this lift in one more workout to see progress.", style: TextStyle(fontSize: 11, color: AppColors.mute))
                    else
                      SizedBox(
                        height: 130,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _WeightDotsPainter(
                            points: [for (final d in dotsFor(_selected[i])) (d.$1.split("#").first, d.$2)],
                            color: _chartColors[i % _chartColors.length],
                            textColor: AppColors.txt,
                            mute: AppColors.mute,
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    "Weight (lbs) of your heaviest set. Shows where you started plus your last three workouts.",
                    style: TextStyle(fontSize: 10.5, color: AppColors.mute),
                  ),
                  if (squad != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _sharing ? null : () => _shareWithSquad({for (final n in _selected) n: seriesFor(n)!}),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.gold,
                          side: BorderSide(color: AppColors.goldDim),
                          padding: const EdgeInsets.symmetric(vertical: 9),
                        ),
                        icon: _sharing
                            ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold))
                            : const Icon(LucideIcons.users2, size: 14),
                        label: Text(_sharing ? "Sharing…" : "Share with Squad", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Up to four dots joined by a line, each labeled with its weight and the
/// date it was logged, so the chart reads in actual pounds.
class _WeightDotsPainter extends CustomPainter {
  _WeightDotsPainter({required this.points, required this.color, required this.textColor, required this.mute});

  final List<(String, double)> points; // (iso date, weight)
  final Color color;
  final Color textColor;
  final Color mute;

  String _w(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  String _d(String iso) {
    final p = iso.split("-");
    if (p.length < 3) return iso;
    return "${int.tryParse(p[1]) ?? p[1]}/${int.tryParse(p[2]) ?? p[2]}";
  }

  void _text(Canvas c, String t, Offset center, {required Color col, double size = 11, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(color: col, fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const padX = 28.0, top = 22.0, bottom = 22.0;
    final lo = points.map((p) => p.$2).reduce((a, b) => a < b ? a : b);
    final hi = points.map((p) => p.$2).reduce((a, b) => a > b ? a : b);
    final span = hi - lo;
    final plotH = size.height - top - bottom;
    final stepX = points.length == 1 ? 0.0 : (size.width - padX * 2) / (points.length - 1);
    Offset at(int i) {
      final t = span == 0 ? 0.5 : (points[i].$2 - lo) / span;
      return Offset(padX + stepX * i, top + plotH * (1 - t));
    }

    final line = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(path, line);

    for (var i = 0; i < points.length; i++) {
      final o = at(i);
      canvas.drawCircle(o, 6, Paint()..color = color);
      canvas.drawCircle(o, 2.5, Paint()..color = const Color(0xFF111111));
      _text(canvas, _w(points[i].$2), Offset(o.dx, o.dy - 14), col: textColor, size: 12, bold: true);
      _text(canvas, i == 0 ? "Start ${_d(points[i].$1)}" : _d(points[i].$1), Offset(o.dx, size.height - 6), col: mute, size: 10);
    }
  }

  @override
  bool shouldRepaint(covariant _WeightDotsPainter old) =>
      old.points != points || old.color != color || old.textColor != textColor || old.mute != mute;
}
