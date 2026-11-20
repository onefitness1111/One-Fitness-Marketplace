import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../theme/app_colors.dart";
import "../widgets/widgets.dart";
import "client_foreground.dart";
import "motion.dart";

class WorkoutCompleteStats {
  const WorkoutCompleteStats({
    required this.volume,
    required this.sets,
    required this.prs,
    required this.exercises,
    required this.streak,
  });

  final int volume;
  final int sets;
  final int prs;
  final int exercises;
  final int streak;
}

class WorkoutCompleteScreen extends StatefulWidget {
  const WorkoutCompleteScreen({super.key, required this.stats, required this.onDone});

  final WorkoutCompleteStats stats;
  final VoidCallback onDone;

  @override
  State<WorkoutCompleteScreen> createState() => _WorkoutCompleteScreenState();
}

class _WorkoutCompleteScreenState extends State<WorkoutCompleteScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    ClientForeground.pushBlock();
    HapticFeedback.mediumImpact();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (reduceMotionOf(context)) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    });
  }

  @override
  void dispose() {
    ClientForeground.popBlock();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = reduceMotionOf(context) ? 1.0 : _c.value;
    final s = widget.stats;
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text("Workout complete", style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 22),
              _Stat("Volume", (s.volume * t).round().toString()),
              _Stat("Sets", (s.sets * t).round().toString()),
              _Stat("PRs", (s.prs * t).round().toString()),
              _Stat("Exercises", (s.exercises * t).round().toString()),
              const SizedBox(height: 18),
              Row(
                children: [
                  SizedBox(
                    width: 54,
                    height: 54,
                    child: CircularProgressIndicator(
                      value: (s.streak <= 0 ? 0 : (s.streak / 7).clamp(0.0, 1.0)) * t,
                      strokeWidth: 4,
                      color: Colors.white,
                      backgroundColor: AppColors.line,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text("${s.streak} day streak", style: TextStyle(color: AppColors.txt, fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
              const Spacer(),
              BtnGold(full: true, onPressed: widget.onDone, child: const Text("Done")),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: AppColors.mute, fontSize: 14))),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
