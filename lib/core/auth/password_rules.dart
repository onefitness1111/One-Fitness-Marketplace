/// Supabase Auth's default minimum. Signup already uses the same bar.
const kMinPasswordLength = 6;

const kPasswordResetRedirect = "onefitness://reset-password";

/// Null when the pair can be saved.
String? passwordChangeError(String next, String confirm) {
  if (next.length < kMinPasswordLength) {
    return "Use at least $kMinPasswordLength characters.";
  }
  if (next != confirm) return "Those passwords don't match.";
  return null;
}
