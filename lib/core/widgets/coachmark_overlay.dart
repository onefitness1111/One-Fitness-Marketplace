import "package:flutter/material.dart";
import "../theme/app_colors.dart";
import "../../data/models/tour_step.dart";
import "app_buttons.dart";

/// The ring around a highlighted button. It always sits on the dark shade,
/// in light mode and in dark mode, so the brand gray stays visible in both.
const kCoachmarkRing = Color(0xFFD9D9D9);

/// A full-screen walkthrough that spotlights one real on-screen widget at a
/// time and explains it. Tapping the shade moves ahead. Tapping the card
/// does not. Skip and Got it both finish the tour.
class CoachmarkOverlay extends StatefulWidget {
  const CoachmarkOverlay({
    super.key,
    required this.steps,
    required this.keys,
    required this.onDone,
    this.initialKey,
    this.onPause,
  });

  final List<TourStep> steps;
  final Map<String, GlobalKey> keys;
  final VoidCallback onDone;

  /// Resume here instead of at the first step. Used when the menu was closed
  /// mid-tour so the next open continues rather than starting over.
  final String? initialKey;

  /// The step that was on screen when the overlay was taken down without
  /// Skip or Got it.
  final ValueChanged<String>? onPause;

  @override
  State<CoachmarkOverlay> createState() => _CoachmarkOverlayState();
}

class _CoachmarkOverlayState extends State<CoachmarkOverlay> {
  int _i = 0;
  Rect? _rect;
  List<TourStep> _steps = const [];
  bool _ready = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _settle());
  }

  @override
  void dispose() {
    if (!_finished && _steps.isNotEmpty && _i < _steps.length) {
      widget.onPause?.call(_steps[_i].key);
    }
    super.dispose();
  }

  /// Build the list from the real steps, not from whichever rows happened
  /// to be on screen in the first frame. Rows below the fold are scrolled
  /// into view in [_focus] before they are highlighted. A step whose button
  /// is not in the tree at all is left out, so the counter has no gaps.
  Future<void> _settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;
    final ready = widget.steps.where((s) => widget.keys[s.key]?.currentContext != null).toList();
    if (ready.isEmpty) {
      _finished = true;
      widget.onDone();
      return;
    }
    var start = 0;
    final resume = widget.initialKey;
    if (resume != null) {
      final at = ready.indexWhere((s) => s.key == resume);
      if (at >= 0) start = at;
    }
    setState(() {
      _steps = ready;
      _i = start;
      _ready = true;
    });
    await _focus();
  }

  Future<void> _focus() async {
    if (!mounted || _steps.isEmpty || _i >= _steps.length) return;
    final key = widget.keys[_steps[_i].key];
    final target = key?.currentContext;
    _measure();
    if (target != null) {
      await Scrollable.ensureVisible(
        target,
        alignment: 0.4,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      if (mounted) _measure();
    }
  }

  void _measure() {
    if (!mounted || _steps.isEmpty || _i >= _steps.length) return;
    final key = widget.keys[_steps[_i].key];
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    final next = box != null && box.attached ? (box.localToGlobal(Offset.zero) & box.size) : null;
    if (next != _rect) setState(() => _rect = next);
  }

  void _complete() {
    if (_finished) return;
    _finished = true;
    widget.onDone();
  }

  void _advance() {
    if (_steps.isEmpty || _finished) return;
    if (_i >= _steps.length - 1) {
      _complete();
      return;
    }
    setState(() {
      _i++;
      _rect = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _steps.isEmpty) return const SizedBox.shrink();
    final step = _steps[_i];
    final last = _i == _steps.length - 1;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final rect = _rect;
    final bubbleW = (screen.width - 24).clamp(220.0, 320.0);
    final safe = media.padding;
    final bubbleLeft = rect == null ? 12.0 : rect.left.clamp(12.0, screen.width - bubbleW - 12.0);
    final arrowX = rect == null ? bubbleW / 2 : (rect.center.dx - bubbleLeft).clamp(20.0, bubbleW - 20.0);

    return GestureDetector(
      onTap: _advance,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _SpotlightPainter(rect: rect)),
            ),
          ),
          if (rect != null)
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _BubbleLayout(target: rect, width: bubbleW, safe: safe),
                child: GestureDetector(
                  onTap: () {},
                  child: _CoachmarkCard(
                    step: step,
                    index: _i,
                    total: _steps.length,
                    last: last,
                    width: bubbleW,
                    arrowX: arrowX,
                    target: rect,
                    onSkip: _complete,
                    onNext: _advance,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CoachmarkCard extends StatefulWidget {
  const _CoachmarkCard({
    required this.step,
    required this.index,
    required this.total,
    required this.last,
    required this.width,
    required this.arrowX,
    required this.target,
    required this.onSkip,
    required this.onNext,
  });

  final TourStep step;
  final int index;
  final int total;
  final bool last;
  final double width;
  final double arrowX;
  final Rect target;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  @override
  State<_CoachmarkCard> createState() => _CoachmarkCardState();
}

class _CoachmarkCardState extends State<_CoachmarkCard> {
  /// True when the card sits under the highlighted button, so the pointer
  /// aims up. Measured from where this card actually landed.
  bool _pointUp = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _aim());
  }

  @override
  void didUpdateWidget(covariant _CoachmarkCard old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) => _aim());
  }

  void _aim() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final up = top >= widget.target.bottom - 2;
    if (up != _pointUp) setState(() => _pointUp = up);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final card = Container(
      constraints: BoxConstraints(maxHeight: screen.height - safe.top - safe.bottom - 36),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.goldDim, width: 1.5),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "${widget.index + 1} of ${widget.total}",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.txt, fontWeight: FontWeight.w700, decoration: TextDecoration.none),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (widget.index + 1) / widget.total,
                minHeight: 4,
                backgroundColor: AppColors.line,
                valueColor: AlwaysStoppedAnimation(AppColors.gold),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.step.title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.txt, decoration: TextDecoration.none),
            ),
            const SizedBox(height: 4),
            Text(
              widget.step.desc,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.txt, height: 1.4, decoration: TextDecoration.none),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                BtnGhost(onPressed: widget.onSkip, child: const Text("Skip")),
                BtnGold(onPressed: widget.onNext, child: Text(widget.last ? "Got it" : "Next")),
              ],
            ),
          ],
        ),
      ),
    );

    final pointer = Semantics(
      label: "Points at the highlighted button",
      child: CustomPaint(
        size: Size(widget.width, 9),
        painter: _PointerPainter(up: _pointUp, centerX: widget.arrowX),
      ),
    );

    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pointUp) pointer,
          card,
          if (!_pointUp) pointer,
        ],
      ),
    );
  }
}

class _PointerPainter extends CustomPainter {
  const _PointerPainter({required this.up, required this.centerX});
  final bool up;
  final double centerX;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = centerX.clamp(14.0, size.width - 14.0);
    final path = Path();
    if (up) {
      path
        ..moveTo(mid - 8, size.height)
        ..lineTo(mid, 0)
        ..lineTo(mid + 8, size.height)
        ..close();
    } else {
      path
        ..moveTo(mid - 8, 0)
        ..lineTo(mid, size.height)
        ..lineTo(mid + 8, 0)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = AppColors.card);
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.goldDim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _PointerPainter old) => old.up != up || old.centerX != centerX;
}

/// Places the card below the spotlight when it fits, otherwise above it,
/// and keeps every edge inside the safe area.
class _BubbleLayout extends SingleChildLayoutDelegate {
  _BubbleLayout({required this.target, required this.width, required this.safe});
  final Rect target;
  final double width;
  final EdgeInsets safe;

  static const _gap = 14.0;
  static const _margin = 12.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: constraints.maxHeight);

  @override
  Offset getPositionForChild(Size size, Size child) {
    final minTop = safe.top + _margin;
    final maxTop = size.height - safe.bottom - _margin - child.height;
    final below = target.bottom + _gap;
    final above = target.top - _gap - child.height;
    final fitsBelow = below + child.height <= size.height - safe.bottom - _margin;
    var top = fitsBelow ? below : above;
    top = top.clamp(minTop, maxTop < minTop ? minTop : maxTop);
    final left = target.left.clamp(_margin, size.width - width - _margin);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(covariant _BubbleLayout old) => old.target != target || old.width != width || old.safe != safe;
}

/// Dark shade with a hole around [rect], and a light-gray ring that stays
/// on screen even when the button sits against the bottom edge.
class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({required this.rect});
  final Rect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = const Color(0xCC060607);
    if (rect == null) {
      canvas.drawRect(Offset.zero & size, scrim);
      return;
    }
    // Pull the ring in so a bottom tab is not clipped by the screen edge.
    final inflated = rect!.inflate(4);
    const edge = 3.0;
    final left = inflated.left.clamp(edge, size.width - edge - 8);
    final top = inflated.top.clamp(edge, size.height - edge - 8);
    final right = inflated.right.clamp(left + 8, size.width - edge);
    final bottom = inflated.bottom.clamp(top + 8, size.height - edge);
    final hole = RRect.fromRectAndRadius(Rect.fromLTRB(left, top, right, bottom), const Radius.circular(12));
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(path, scrim);
    canvas.drawRRect(
      hole,
      Paint()
        ..color = kCoachmarkRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) => oldDelegate.rect != rect;
}
