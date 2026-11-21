import "../web/portal_path.dart";

/// Shown when a password-reset link cannot be used.
const kRecoveryLinkFailed =
    "This reset link has expired or was already used. Request a new one from the sign-in page.";

/// The pieces Supabase puts on the redirect after a reset email is opened.
class RecoveryLink {
  const RecoveryLink({
    this.code,
    this.tokenHash,
    this.accessToken,
    this.refreshToken,
    this.type,
    this.error,
    this.errorDescription,
  });

  final String? code;
  final String? tokenHash;
  final String? accessToken;
  final String? refreshToken;
  final String? type;
  final String? error;
  final String? errorDescription;

  bool get hasError => error != null && error!.isNotEmpty;

  bool get canExchange {
    if (hasError) return false;
    if (tokenHash != null && tokenHash!.isNotEmpty) return true;
    if (code != null && code!.isNotEmpty) return true;
    if (accessToken != null &&
        accessToken!.isNotEmpty &&
        refreshToken != null &&
        refreshToken!.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Query string and hash fragment, so both the PKCE `?code=` link and the
  /// older `#access_token=` link are recognised.
  static RecoveryLink? parse(Uri uri) {
    final query = uri.queryParameters;
    final fragment = Uri.splitQueryString(uri.fragment);
    String? pick(String key) {
      final fromQuery = query[key];
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
      final fromFragment = fragment[key];
      if (fromFragment != null && fromFragment.isNotEmpty) return fromFragment;
      return null;
    }

    final link = RecoveryLink(
      code: pick("code"),
      tokenHash: pick("token_hash"),
      accessToken: pick("access_token"),
      refreshToken: pick("refresh_token"),
      type: pick("type"),
      error: pick("error"),
      errorDescription: pick("error_description"),
    );
    if (!link.canExchange && !link.hasError) return null;
    return link;
  }
}

String recoveryErrorMessage(RecoveryLink link) {
  final raw = (link.errorDescription ?? "").replaceAll("+", " ").trim();
  if (raw.isEmpty) return kRecoveryLinkFailed;
  final sentence = raw.endsWith(".") ? raw : "$raw.";
  return "$sentence Request a new one from the sign-in page.";
}

/// True when this URL is a password-reset landing, not a Stripe return or
/// some other query string.
bool isPasswordRecoveryUri(Uri uri, RecoveryLink link) {
  if (link.type == "recovery") return true;
  return PortalPath.isReset(uri.path);
}
