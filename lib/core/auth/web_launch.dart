import "package:flutter_riverpod/flutter_riverpod.dart";

import "../supabase/supabase_service.dart";
import "recovery_link.dart";

/// Overridden in main when the site was opened from a reset link.
final webLaunchProvider = Provider<WebLaunchPlan>((ref) => WebLaunchPlan.none);

/// The address the website was opened on. Null on the phone.
///
/// The exchange itself waits until Supabase is up, after the first frame.
final webLaunchUriProvider = Provider<Uri?>((ref) => null);

enum WebLaunchKind { none, setPassword, error }

/// What the website should do with the address it was opened on.
class WebLaunchPlan {
  const WebLaunchPlan._(this.kind, this.message);

  final WebLaunchKind kind;
  final String? message;

  static const none = WebLaunchPlan._(WebLaunchKind.none, null);

  const WebLaunchPlan.setPassword() : this._(WebLaunchKind.setPassword, null);

  const WebLaunchPlan.error(String message) : this._(WebLaunchKind.error, message);
}

/// Decides from the URL alone. No network, so tests can cover it.
WebLaunchPlan planWebLaunch(Uri uri) {
  final link = RecoveryLink.parse(uri);
  if (link == null) return WebLaunchPlan.none;
  if (!isPasswordRecoveryUri(uri, link)) return WebLaunchPlan.none;
  if (link.hasError || !link.canExchange) {
    return WebLaunchPlan.error(recoveryErrorMessage(link));
  }
  return const WebLaunchPlan.setPassword();
}

/// Exchanges a reset link for a session, after Supabase has started.
/// A bad or reused link becomes an error plan instead of crashing startup.
Future<WebLaunchPlan> consumeWebLaunch(Uri uri) async {
  final plan = planWebLaunch(uri);
  if (plan.kind != WebLaunchKind.setPassword) return plan;
  try {
    await SupabaseService.adoptRecoveryLink(uri);
    if (SupabaseService.currentUser == null) {
      return const WebLaunchPlan.error(kRecoveryLinkFailed);
    }
    return plan;
  } catch (_) {
    return const WebLaunchPlan.error(kRecoveryLinkFailed);
  }
}
