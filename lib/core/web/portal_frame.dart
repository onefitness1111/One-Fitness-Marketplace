import "package:flutter/material.dart";

import "../theme/app_colors.dart";

/// Phone-sized layouts stay full width. A wide browser gets a centered
/// column so the same screens stay readable on a desktop monitor.
const double kPortalMaxWidth = 720;

class PortalFrame extends StatelessWidget {
  const PortalFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite || constraints.maxWidth <= kPortalMaxWidth) {
          return child;
        }
        return ColoredBox(
          color: AppColors.bg,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: kPortalMaxWidth,
              height: constraints.maxHeight,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
