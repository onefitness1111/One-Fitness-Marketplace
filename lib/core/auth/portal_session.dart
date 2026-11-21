/// How the website keeps someone signed in.
///
/// Supabase stores the session in the browser (local storage) and refreshes
/// the access token before it expires. Sign-out deletes that storage.
/// Closing the tab does not.
class PortalSessionPolicy {
  const PortalSessionPolicy._();

  static const persistSession = true;
  static const autoRefreshToken = true;
}
