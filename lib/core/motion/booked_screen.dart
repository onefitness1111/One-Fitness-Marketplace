import "package:flutter/material.dart";

import "../theme/app_colors.dart";
import "../widgets/widgets.dart";
import "motion.dart";

/// Client confirmation. Done is tappable the whole time. The check and the
/// copy finish in about 1.6 seconds.
class BookedScreen extends StatefulWidget {
  const BookedScreen({super.key, required this.when, required this.coach, required this.place});

  final String when;
  final String coach;
  final String place;

  static Future<void> show(BuildContext context, {required String when, required String coach, required String place}) {
    return Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: motionExpand,
      pageBuilder: (_, _, _) => BookedScreen(when: when, coach: coach, place: place),
    ));
  }

  @override
  State<BookedScreen> createState() => _BookedScreenState();
}

class _BookedScreenState extends State<BookedScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = reduceMotionOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = reduced ? 1.0 : _c.value;
              final check = (t / 0.35).clamp(0.0, 1.0);
              final copy = ((t - 0.3) / 0.4).clamp(0.0, 1.0);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Spacer(),
                  Transform.scale(
                    scale: check,
                    child: Icon(Icons.check, size: 42, color: Colors.white),
                  ),
                  const SizedBox(height: 18),
                  Opacity(
                    opacity: copy,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("You're booked", style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        Text(widget.when, style: TextStyle(color: AppColors.txt, fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(widget.coach, style: TextStyle(color: AppColors.mute, fontSize: 15)),
                        if (widget.place.trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(widget.place, style: TextStyle(color: AppColors.mute, fontSize: 15)),
                        ],
                      ],
                    ),
                  ),
                  const Spacer(),
                  BtnGold(
                    full: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text("Done"),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
