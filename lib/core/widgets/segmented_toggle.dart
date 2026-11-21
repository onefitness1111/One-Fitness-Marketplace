import "package:flutter/material.dart";

import "../motion/motion.dart";
import "../theme/app_colors.dart";
import "tap_highlight.dart";

/// The nutrition page's segmented control: one track, equal segments, the
/// selected one filled with the same light chip.
///
/// Training Day / Rest Day and Log food / Meals / Grocery list both used
/// this. The fill slides to the tapped segment. At rest it is the same
/// chip as before, so a caller that only checks the settled color still
/// sees it.
class SegmentedToggle extends StatefulWidget {
  const SegmentedToggle({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.itemKeys,
    this.fontSize = 12,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  /// One key per label, in order. Nutrition pins the three it already had.
  final List<Key>? itemKeys;

  /// 12 for the day toggle, 11 for the three nutrition panels.
  final double fontSize;

  @override
  State<SegmentedToggle> createState() => _SegmentedToggleState();
}

class _SegmentedToggleState extends State<SegmentedToggle> with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  late int _from;

  @override
  void initState() {
    super.initState();
    _from = widget.index;
    _slide = AnimationController(vsync: this, duration: motionEnter, value: 1);
  }

  @override
  void didUpdateWidget(SegmentedToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _from = oldWidget.index;
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (var i = 0; i < widget.labels.length; i++)
            Expanded(
              child: TapHighlight(
                key: widget.itemKeys != null && i < widget.itemKeys!.length ? widget.itemKeys![i] : null,
                onTap: () => widget.onChanged(i),
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (i == widget.index)
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _slide,
                          builder: (context, child) {
                            return LayoutBuilder(
                              builder: (context, constraints) {
                                final t = Curves.easeOut.transform(_slide.value);
                                final dx = constraints.maxWidth * (_from - widget.index) * (1 - t);
                                return Transform.translate(offset: Offset(dx, 0), child: child);
                              },
                            );
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.gold,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                      ),
                    Container(
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
                          color: i == widget.index ? AppColors.onGold : AppColors.mute,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
