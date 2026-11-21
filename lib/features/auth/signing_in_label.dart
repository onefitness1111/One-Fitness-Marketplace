import "package:flutter/material.dart";

import "../../core/theme/app_colors.dart";

/// Gold-button contents while a sign-in is in flight.
///
/// The label used to be plain text, so a multi-second wait looked frozen.
class SigningInLabel extends StatelessWidget {
  const SigningInLabel({super.key, this.label = "Signing in…"});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onGold),
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
