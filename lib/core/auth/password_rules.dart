/// Supabase Auth's default minimum. Signup already uses the same bar.
const kMinPasswordLength = 6;

/// The phone app opens this custom link from the reset email.
const kMobilePasswordResetRedirect = "onefitness://reset-password";

/// Same value as [kMobilePasswordResetRedirect]. Existing call sites keep this name.
const kPasswordResetRedirect = kMobilePasswordResetRedirect;

/// The website. Must be listed in Supabase Auth → Redirect URLs, exactly.
const kWebPasswordResetRedirect = "https://portal.onefitnessworkout.com/reset-password";

String passwordResetRedirectFor({required bool onWeb}) =>
    onWeb ? kWebPasswordResetRedirect : kMobilePasswordResetRedirect;

String passwordResetSentMessage({required bool onWeb}) => onWeb
    ? "Reset email sent. Open the link in this browser to choose a new password."
    : "Reset email sent. Open it on this phone.";

/// Null when the pair can be saved.
String? passwordChangeError(String next, String confirm) {
  if (next.length < kMinPasswordLength) {
    return "Use at least $kMinPasswordLength characters.";
  }
  if (next != confirm) return "Those passwords don't match.";
  return null;
}
