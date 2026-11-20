import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/coach/coach_public_stats.dart";
import "../../../core/coach/next_open_slot.dart";
import "../../../core/motion/motion.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/address_utils.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/unavailability.dart";
import "../../../core/utils/domain_labels.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/trainer.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";

/// Full coach profile. There is no coach search or list.
class CoachProfileScreen extends ConsumerStatefulWidget {
  const CoachProfileScreen({super.key, required this.trainer, this.onBook});

  final Trainer trainer;
  final VoidCallback? onBook;

  static Future<void> open(BuildContext context, Trainer trainer, {VoidCallback? onBook}) {
    return Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 900),
      reverseTransitionDuration: motionPress,
      pageBuilder: (_, animation, _) => CoachProfileScreen(trainer: trainer, onBook: onBook),
      transitionsBuilder: (context, animation, _, child) {
        if (reduceMotionOf(context)) return child;
        final t = animation.value;
        final zoom = t < 0.45;
        return Stack(
          children: [
            child,
            if (zoom)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Avatar(src: trainer.photo, name: trainer.displayTitle, size: 220, active: true),
                  ),
                ),
              ),
          ],
        );
      },
    ));
  }

  @override
  ConsumerState<CoachProfileScreen> createState() => _CoachProfileScreenState();
}

class _CoachProfileScreenState extends ConsumerState<CoachProfileScreen> {
  StarCounts _stars = const StarCounts();
  int? _rebook;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final summary = await SupabaseService.coachReviewSummary(widget.trainer.id);
      if (!mounted) return;
      setState(() {
        _stars = summary.stars;
        _rebook = summary.rebookPercent;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  String get _place {
    final named = widget.trainer.locations.where((l) => l.name.trim().isNotEmpty).map((l) => l.name.trim());
    if (named.isNotEmpty) return named.join(" · ");
    final own = (widget.trainer.locationName ?? "").trim();
    if (own.isNotEmpty) return own;
    final address = widget.trainer.locations.isNotEmpty
        ? (widget.trainer.locations.first.address ?? "")
        : (widget.trainer.locationAddress ?? "");
    final parts = AddressParts.parse(address);
    if (parts.city.isEmpty) return "";
    final st = stateCode(parts.state);
    return st.isEmpty ? parts.city : "${parts.city}, $st";
  }

  @override
  Widget build(BuildContext context) {
    final trainer = widget.trainer;
    final types = trainer.offeredSessionTypes.map(sessionTypeLabel).toSet();
    final disciplines = trainer.offeredDisciplines
        .where((d) => d != "assessment" && d != "programmer")
        .map(disciplineLabel)
        .toSet();
    final bookings = ref.watch(allBookingsProvider);
    final blocked = ref.watch(blockedTimesProvider);
    final next = nextOpenSlot(
      trainer: trainer,
      bookings: bookings,
      blocked: blocked,
      today: isoToday(),
    );
    final frames = trainer.beforeAfters
        .where((f) => (f.left ?? "").isNotEmpty || (f.right ?? "").isNotEmpty)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.chevron_left, color: AppColors.txt),
                      ),
                      Avatar(src: trainer.photo, name: trainer.displayTitle, size: 64, active: true),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(trainer.displayTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                            if (_place.isNotEmpty)
                              Text(_place, style: TextStyle(color: AppColors.mute, fontSize: 13)),
                            for (final u in upcomingUnavailability(trainer, isoToday()))
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  clientUnavailabilityText(u),
                                  style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.3),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_loaded && _stars.showStars)
                    TapHighlight(
                      onTap: () => _StarBreakdown.show(context, _stars),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          "${_stars.average!.toStringAsFixed(1)} · ${_stars.total} reviews",
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ),
                    ),
                  if (_loaded && _stars.showStars)
                    TapHighlight(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => CoachReviewsPage(trainerId: trainer.id, trainerName: trainer.displayTitle),
                      )),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text("Reviews", style: TextStyle(color: AppColors.mute, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  if (types.isNotEmpty || disciplines.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final label in [...types, ...disciplines]) Tag(text: label),
                      ],
                    ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text("Bio", style: TextStyle(fontWeight: FontWeight.w800)),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          (trainer.bio ?? "").trim().isEmpty ? "No bio yet." : trainer.bio!.trim(),
                          style: TextStyle(color: AppColors.txt, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                  if (next != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        "Next open · ${niceDate(next.date)} at ${fmtSlot(next.slot)}",
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  if (_rebook != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text("$_rebook% of clients rebook", style: TextStyle(color: AppColors.mute, fontWeight: FontWeight.w700)),
                    ),
                  if (frames.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text("Before and after", style: TextStyle(color: AppColors.mute, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text("${frames.length} photo ${frames.length == 1 ? "pair" : "pairs"}", style: TextStyle(color: AppColors.txt)),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: BtnGold(
                full: true,
                onPressed: widget.onBook ?? () => Navigator.of(context).pop(),
                child: const Text("Book"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StarBreakdown extends StatelessWidget {
  const _StarBreakdown({required this.counts});
  final StarCounts counts;

  static Future<void> show(BuildContext context, StarCounts counts) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      builder: (_) => _StarBreakdown(counts: counts),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final stars in [5, 4, 3, 2, 1])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(width: 16, child: Text("$stars", style: const TextStyle(fontWeight: FontWeight.w800))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: counts.fraction(stars),
                        minHeight: 8,
                        color: Colors.white,
                        backgroundColor: AppColors.line,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(width: 28, child: Text("${counts.countFor(stars)}", textAlign: TextAlign.right)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class CoachReviewsPage extends StatefulWidget {
  const CoachReviewsPage({super.key, required this.trainerId, required this.trainerName});

  final String trainerId;
  final String trainerName;

  @override
  State<CoachReviewsPage> createState() => _CoachReviewsPageState();
}

class _CoachReviewsPageState extends State<CoachReviewsPage> {
  int? _stars = 5;
  final _rows = <CoachReviewLine>[];
  bool _loading = false;
  bool _more = true;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final page = await SupabaseService.coachReviewsPage(
        trainerId: widget.trainerId,
        stars: _stars,
        offset: reset ? 0 : _rows.length,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(page);
        _more = page.length >= 20;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.txt,
        title: Text(widget.trainerName, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final choice in <int?>[null, 5, 4, 3, 2, 1])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(choice == null ? "All" : "$choice"),
                      selected: _stars == choice,
                      onSelected: (_) {
                        setState(() => _stars = choice);
                        _load(reset: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _rows.length + (_more ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _rows.length) {
                  return TextButton(
                    onPressed: _loading ? null : () => _load(reset: false),
                    child: Text(_loading ? "Loading" : "More"),
                  );
                }
                final row = _rows[i];
                final when = row.createdAt;
                final label = when == null ? "" : "${_month(when.month)} ${when.year}";
                return ListTile(
                  title: Text("Client · $label", style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text("${row.stars} · ${(row.body ?? "").trim()}".trim()),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _month(int month) {
  const names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  if (month < 1 || month > 12) return "";
  return names[month - 1];
}
