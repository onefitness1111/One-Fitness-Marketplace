import "package:flutter/widgets.dart";

/// Shared timing. Effects stay short so the app never feels like it is waiting.
const motionPress = Duration(milliseconds: 150);
const motionEnter = Duration(milliseconds: 220);
const motionExpand = Duration(milliseconds: 280);

bool reduceMotionOf(BuildContext context) => MediaQuery.disableAnimationsOf(context);
