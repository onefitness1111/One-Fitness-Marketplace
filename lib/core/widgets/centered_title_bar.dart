import "package:flutter/material.dart";
import "../theme/app_colors.dart";

/// Page name centered on the screen, with the menu, Back, and other buttons
/// sitting on the edges. The name does not slide when Back appears, because
/// it is centered on the whole bar rather than in the gap between buttons.
class CenteredTitleBar extends StatelessWidget {
  const CenteredTitleBar({
    super.key,
    required this.title,
    required this.leading,
    this.trailing = const [],
  });

  final String title;
  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 108),
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                letterSpacing: 0.3,
                color: AppColors.txt,
              ),
            ),
          ),
          Row(
            children: [
              ...leading,
              const Spacer(),
              ...trailing,
            ],
          ),
        ],
      ),
    );
  }
}
