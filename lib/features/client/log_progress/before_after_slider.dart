import "package:flutter/material.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/progress_photo_view.dart";
import "../../../data/models/progress_photo.dart";

/// Drag between the oldest progress photo and the newest.
class BeforeAfterSlider extends StatefulWidget {
  const BeforeAfterSlider({super.key, required this.before, required this.after});

  final ProgressPhoto before;
  final ProgressPhoto after;

  @override
  State<BeforeAfterSlider> createState() => _BeforeAfterSliderState();
}

class _BeforeAfterSliderState extends State<BeforeAfterSlider> {
  double _split = 0.5;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Before and after", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 4),
        Text("Drag to compare.", style: TextStyle(fontSize: 12, color: AppColors.mute)),
        const SizedBox(height: 10),
        AspectRatio(
          aspectRatio: 3 / 4,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                onHorizontalDragUpdate: (d) {
                  setState(() => _split = ((_split * width + d.delta.dx) / width).clamp(0.04, 0.96));
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: AppColors.card, child: ProgressPhotoView(photo: widget.before)),
                      ClipRect(
                        clipper: _RightClipper(_split),
                        child: ColoredBox(color: AppColors.card, child: ProgressPhotoView(photo: widget.after)),
                      ),
                      Positioned(
                        left: width * _split - 1,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 2, color: AppColors.txt),
                      ),
                      Positioned(
                        left: width * _split - 14,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: AppColors.txt,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.bg, width: 2),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: _tag("Before ${widget.before.date}"),
                      ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: _tag("After ${widget.after.date}"),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tag(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

class _RightClipper extends CustomClipper<Rect> {
  _RightClipper(this.split);
  final double split;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(size.width * split, 0, size.width * (1 - split), size.height);

  @override
  bool shouldReclip(_RightClipper old) => old.split != split;
}
