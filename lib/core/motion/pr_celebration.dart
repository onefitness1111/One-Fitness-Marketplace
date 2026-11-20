import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../theme/app_colors.dart";
import "motion.dart";
import "pr_bus.dart";

/// ~1.2s black card. A tap skips it. Reduce Motion is a short fade.
class PrCelebration extends StatefulWidget {
  const PrCelebration({super.key, required this.flash, required this.onDone});

  final PrFlash flash;
  final VoidCallback onDone;

  @override
  State<PrCelebration> createState() => _PrCelebrationState();
}

class _PrCelebrationState extends State<PrCelebration> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _c.forward().whenComplete(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _skip() {
    if (_c.isCompleted) return;
    _c.value = 1;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = reduceMotionOf(context);
    return GestureDetector(
      onTap: _skip,
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = reduced ? 1.0 : _c.value;
              final grow = (t / 0.2).clamp(0.0, 1.0);
              final countT = ((t - 0.25) / 0.45).clamp(0.0, 1.0);
              final shrink = t < 0.82 ? 1.0 : (1 - (t - 0.82) / 0.18).clamp(0.0, 1.0);
              final shown = widget.flash.fromWeight + (widget.flash.toWeight - widget.flash.fromWeight) * countT;
              return Opacity(
                opacity: reduced ? (t > 0 ? 1 : 0) : shrink,
                child: Transform.scale(
                  scale: 0.86 + 0.14 * grow,
                  child: Container(
                    width: 280,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
                    color: Colors.black,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text("NEW PR", style: TextStyle(color: AppColors.txt, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                        const SizedBox(height: 8),
                        Text(widget.flash.exercise, textAlign: TextAlign.center, style: TextStyle(color: AppColors.mute, fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 10),
                        Text(
                          shown.toStringAsFixed(shown.truncateToDouble() == shown ? 0 : 1),
                          style: TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w800, height: 1),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
