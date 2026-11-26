/// The word "AI", and every AI control, is for the owner account only.
bool ownerSeesAi(String? role) => role == "owner";

/// The whole word AI (any case), "A.I.", and names of AI products and
/// companies. Ordinary words and names that only contain the letters "ai"
/// (Aiden, Craig, again, email, failed, MAIN) do not match.
///
/// Same list as supabase/functions/_shared/aiWords.mjs.
final RegExp _aiWord = RegExp(
  r"(?<![A-Za-z0-9])(ai|a\.i\.?|openai|chatgpt|gpt(-?\d[\w.]*)?|llms?|anthropic|artificial intelligence)(?![A-Za-z0-9])",
  caseSensitive: false,
);

/// "AI" glued to the end of a word, like "OpenAI" or "GenAI", or a plural
/// "AIs". Case-sensitive so "MAIN" and "EMAIL" are left alone.
final RegExp _aiSuffix = RegExp(r"(?<=[a-z])AI(?![A-Za-z0-9])|(?<![A-Za-z0-9])AIs(?![A-Za-z0-9])");

/// True when [text] mentions AI as a word, not just the letters "ai".
bool mentionsAi(String? text) {
  final t = text ?? "";
  if (t.isEmpty) return false;
  return _aiWord.hasMatch(t) || _aiSuffix.hasMatch(t);
}

/// A program made with AI is shown to coaches and clients as an ordinary
/// program. Anything that says where it came from is blank for them.
String attributionForRole(String? value, {required bool isOwner}) {
  if (isOwner) return value ?? "";
  final v = (value ?? "").trim();
  if (mentionsAi(v)) return "";
  return v;
}

/// User-facing copy. Owners keep the original sentence. Everyone else gets
/// nothing when the sentence mentions AI.
String ownerOnlyAiText(String text, {required bool isOwner}) {
  if (isOwner) return text;
  if (!mentionsAi(text)) return text;
  return "";
}

/// Text a client is about to see (a server message, an error). When it
/// mentions AI, [fallback] is shown instead.
String clientSafeText(String text, {required String fallback}) =>
    mentionsAi(text) ? fallback : text;
