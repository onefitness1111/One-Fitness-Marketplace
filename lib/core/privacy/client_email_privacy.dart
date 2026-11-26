/// Client email addresses are for the owner only (C10). Coaches never see a
/// client's email, never get a "No email on file" line, and can't find a
/// client by typing part of an email. The server already withholds the
/// column from coaches; this keeps the screens from relying on that.

/// True only for the owner account.
bool canSeeClientEmail({required bool viewerIsOwner}) => viewerIsOwner;

/// The email line to show, or null when there is nothing this viewer may see.
String? clientEmailForViewer(String? email, {required bool viewerIsOwner}) {
  if (!viewerIsOwner) return null;
  final e = (email ?? "").trim();
  return e.isEmpty ? null : e;
}

/// Whether a client matches a search. Everyone can search by name. Only the
/// owner can search by email. [query] is already trimmed and lowercased.
bool clientMatchesSearch({
  required String name,
  required String? email,
  required String query,
  required bool viewerIsOwner,
}) {
  if (query.isEmpty) return true;
  if (name.toLowerCase().contains(query)) return true;
  return viewerIsOwner && (email ?? "").toLowerCase().contains(query);
}
