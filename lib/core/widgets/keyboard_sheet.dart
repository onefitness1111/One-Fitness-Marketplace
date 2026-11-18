import "package:flutter/material.dart";
import "../theme/app_colors.dart";

/// A bottom sheet that sits above the keyboard.
///
/// Small centered pop-ups stay put when the keyboard opens, so the field
/// and the Save button end up underneath it. This sheet adds the keyboard's
/// height as padding and scrolls, the same way the schedule sheets do.
Future<T?> showKeyboardSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) {
      final keyboard = MediaQuery.viewInsetsOf(ctx).bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + keyboard),
        child: SingleChildScrollView(
          child: builder(ctx),
        ),
      );
    },
  );
}

/// How tall a picker sheet should be once the keyboard is open: never a
/// fixed 560 that runs under the keys, and never taller than the space left.
double keyboardSheetHeight(BuildContext context, {double preferred = 560}) {
  final keyboard = MediaQuery.viewInsetsOf(context).bottom;
  final available = MediaQuery.sizeOf(context).height - keyboard - 24;
  if (available < 280) return 280;
  return available < preferred ? available : preferred;
}
