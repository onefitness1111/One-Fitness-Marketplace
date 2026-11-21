import "package:flutter/material.dart";

import "../motion/motion.dart";
import "../theme/app_colors.dart";
import "tap_highlight.dart";

/// The nutrition page's pill control, shared for the rest of the app.
///
/// One track, equal segments, the selected one filled in the same light
/// chip. Nutrition keeps its own copy of this control and is the reference
/// for the settled look: card background, hairline border, 6px radius on
/// the chip, 12px weight-700 labels.
///
/// Pass [position] while a page is moving and the chip follows that
/// fraction. Without it, a tap slides the chip over in 260ms ease-out.
class SegmentedToggle extends StatefulWidget {
  const SegmentedToggle({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.position,
    this.itemKeys,
    this.fontSize = 12,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  /// Fractional segment, for example a [PageView] page. The chip tracks it.
  final double? position;

  final List<Key>? itemKeys;
  final double fontSize;

  @override
  State<SegmentedToggle> createState() => _SegmentedToggleState();
}

class _SegmentedToggleState extends State<SegmentedToggle> with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  late double _from;

  @override
  void initState() {
    super.initState();
    _from = widget.index.toDouble();
    _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);
  }

  @override
  void didUpdateWidget(SegmentedToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.position != null || oldWidget.index == widget.index) return;
    _from = oldWidget.index.toDouble();
    if (reduceMotionOf(context)) {
      _slide.value = 1;
    } else {
      _slide.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  double get _page {
    final last = (widget.labels.length - 1).toDouble();
    if (last <= 0) return 0;
    if (widget.position != null) return widget.position!.clamp(0.0, last);
    final t = Curves.easeOut.transform(_slide.value);
    return (_from + (widget.index - _from) * t).clamp(0.0, last);
  }

  int get _selected {
    final last = widget.labels.length - 1;
    if (last < 0) return 0;
    if (widget.position != null) return widget.position!.round().clamp(0, last);
    return widget.index.clamp(0, last);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Container(
      padding: const EdgeInsets.all(3),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: AnimatedBuilder(
        animation: _slide,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final count = widget.labels.length;
              final width = count == 0 ? 0.0 : constraints.maxWidth / count;
              return Stack(
                children: [
                  Positioned(
                    left: _page * width,
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: DecoratedBox(
                      key: const Key("segment-pill"),
                      decoration: BoxDecoration(
                        color: AppColors.gold,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: TapHighlight(
                            key: widget.itemKeys != null && i < widget.itemKeys!.length ? widget.itemKeys![i] : null,
                            onTap: () => widget.onChanged(i),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
                              alignment: Alignment.center,
                              child: Text(
                                widget.labels[i],
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.fade,
                                style: TextStyle(
                                  fontSize: widget.fontSize,
                                  fontWeight: FontWeight.w700,
                                  color: i == selected ? AppColors.onGold : AppColors.mute,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
