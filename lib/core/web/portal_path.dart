/// Addresses the website understands. Anything else opens the home screen.
class PortalPath {
  const PortalPath._();

  static const home = "/";
  static const login = "/login";
  static const profile = "/profile";
  static const resetPassword = "/reset-password";

  static String normalize(String? raw) {
    if (raw == null || raw.isEmpty) return home;
    var path = raw;
    final query = path.indexOf("?");
    if (query >= 0) path = path.substring(0, query);
    final hash = path.indexOf("#");
    if (hash >= 0) path = path.substring(0, hash);
    if (path.length > 1 && path.endsWith("/")) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.startsWith("/")) path = "/$path";
    return path;
  }

  static bool isLogin(String? raw) => normalize(raw) == login;

  static bool isProfile(String? raw) => normalize(raw) == profile;

  static bool isReset(String? raw) => normalize(raw) == resetPassword;
}

/// The address bar for the screen someone is actually on.
String portalAddress({
  required bool settingPassword,
  required bool clientSignedIn,
  required bool staffSignedIn,
  required String clientScreen,
  required String trainerMode,
}) {
  if (settingPassword) return PortalPath.resetPassword;
  if (!clientSignedIn && !staffSignedIn) return PortalPath.login;
  if (clientSignedIn && clientScreen == "settings") return PortalPath.profile;
  if (staffSignedIn && !clientSignedIn && trainerMode == "myprofile") {
    return PortalPath.profile;
  }
  return PortalPath.home;
}
