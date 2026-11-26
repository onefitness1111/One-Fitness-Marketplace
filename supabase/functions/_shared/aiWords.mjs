// Whole-word AI check, shared by the client nutrition tools (estimate-plate,
// recommend-restaurant). Same list as lib/core/utils/ai_visibility.dart.
//
// Matches the word AI in any case, "A.I.", and names of AI products and
// companies. Names and words that only contain the letters "ai" (Aiden,
// Craig, again, email, failed, MAIN) do not match.

const AI_WORD = /(?<![A-Za-z0-9])(ai|a\.i\.?|openai|chatgpt|gpt(-?\d[\w.]*)?|llms?|anthropic|artificial intelligence)(?![A-Za-z0-9])/i;
const AI_SUFFIX = /(?<=[a-z])AI(?![A-Za-z0-9])|(?<![A-Za-z0-9])AIs(?![A-Za-z0-9])/;

export function mentionsAi(text) {
  const t = String(text ?? "");
  if (!t) return false;
  return AI_WORD.test(t) || AI_SUFFIX.test(t);
}

/// A message a client will see. When it mentions AI, [fallback] instead.
export function clientSafeMessage(text, fallback) {
  const t = String(text ?? "").trim();
  if (!t || mentionsAi(t)) return fallback;
  return t;
}

/// Removes AI words from a short label (a food or dish name).
export function stripAiWords(text) {
  return String(text ?? "")
    .replace(new RegExp(AI_WORD.source, "gi"), "")
    .replace(new RegExp(AI_SUFFIX.source, "g"), "")
    .replace(/\(\s*\)/g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}
