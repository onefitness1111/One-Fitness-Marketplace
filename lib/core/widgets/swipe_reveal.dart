import "package:flutter/material.dart";
import "../theme/app_colors.dart";

/// A row that slides left to reveal one action on the right.
///
/// A quick sideways drag opens it. A long-press is left alone, so a list
/// that also reorders by holding the row can keep doing that.
class SwipeReveal extends StatefulWidget {
  const SwipeReveal({
    super.key,
    required this.child,
    required this.onExchange,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onExchange;
  final bool enabled;

  @override
  State<SwipeReveal> createState() => _SwipeRevealState();
}

class _SwipeRevealState extends State<SwipeReveal> {
  static const _width = 92.0;
  double _offset = 0;

  void _snap(bool open) => setState(() => _offset = open ? -_width : 0);

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: _width,
                child: Material(
                  color: AppColors.txt,
                  child: InkWell(
                    onTap: () {
                      _snap(false);
                      widget.onExchange();
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.swap_vert, color: AppColors.bg, size: 22),
                        const SizedBox(height: 4),
                        Text(
                          "Exchange",
                          style: TextStyle(color: AppColors.bg, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            onHorizontalDragUpdate: (details) {
              setState(() => _offset = (_offset + details.delta.dx).clamp(-_width, 0));
            },
            onHorizontalDragEnd: (details) {
              final fling = details.primaryVelocity ?? 0;
              if (fling < -200 || _offset < -_width / 2) {
                _snap(true);
              } else {
                _snap(false);
              }
            },
            child: Transform.translate(
              offset: Offset(_offset, 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}
