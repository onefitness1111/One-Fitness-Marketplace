import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/widgets.dart";

/// Wide website chrome (side menu, multi-column pages) starts here.
/// Phone browsers and the iPhone/Android app stay on the existing layout.
const double kPortalWideBreakpoint = 840;

/// True when this website window should use the desktop layout.
bool portalWideChrome({required bool web, required double width}) =>
    web && width >= kPortalWideBreakpoint;

bool portalIsWide(BuildContext context) => portalWideChrome(
      web: kIsWeb,
      width: MediaQuery.sizeOf(context).width,
    );
