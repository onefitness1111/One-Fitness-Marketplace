import "package:flutter/material.dart";

import "../theme/app_colors.dart";
import "motion.dart";

/// A gray placeholder that shimmers. It replaces a spinner; it does not
/// add a wait of its own. Reduce Motion holds a still gray block.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 14, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.line;
    final hi = AppColors.card;
    if (reduceMotionOf(context)) {
      return _box(base);
    }
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return _box(Color.lerp(base, hi, _c.value)!);
        },
      ),
    );
  }

  Widget _box(Color color) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(widget.radius)),
    );
  }
}

/// Page-level stand-in for a centered spinner.
class AppLoading extends StatelessWidget {
  const AppLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Skeleton(height: 18),
            SizedBox(height: 10),
            Skeleton(height: 12),
            SizedBox(height: 10),
            Skeleton(width: 140, height: 12),
          ],
        ),
      ),
    );
  }
}
