/// The word "AI", and every AI control, is for the owner account only.
bool ownerSeesAi(String? role) => role == "owner";

/// A program made with AI is shown to coaches and clients as an ordinary
/// program. Anything that says where it came from is blank for them.
String attributionForRole(String? value, {required bool isOwner}) {
  if (isOwner) return value ?? "";
  final v = (value ?? "").trim();
  if (v.toLowerCase().contains("ai")) return "";
  return v;
}

/// User-facing copy. Owners keep the original sentence. Everyone else gets
/// the same sentence with the AI mention removed.
String ownerOnlyAiText(String text, {required bool isOwner}) {
  if (isOwner) return text;
  if (!text.toLowerCase().contains("ai")) return text;
  return "";
}
