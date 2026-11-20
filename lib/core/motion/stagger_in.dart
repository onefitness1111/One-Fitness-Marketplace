import "dart:async";

import "package:flutter/material.dart";

import "motion.dart";

/// Fades and slides a list row in. The child is hit-testable on the first
/// frame, so a tap never waits for the motion.
class StaggerIn extends StatefulWidget {
  const StaggerIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: motionEnter);
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: (widget.index * 40).clamp(0, 200));
    _wait = Timer(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (reduceMotionOf(context)) return widget.child;
    final t = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    return AnimatedBuilder(
      animation: t,
      builder: (context, child) {
        return Opacity(
          opacity: t.value,
          child: Transform.translate(
            offset: Offset(0, (1 - t.value) * 10),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
