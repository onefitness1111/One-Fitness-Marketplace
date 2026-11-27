// Is an FCM v1 send error a sign the device token is dead (app deleted,
// token rotated, or never valid)? Those rows are removed from
// device_tokens so we stop sending to them. Anything else, including a bad
// APNs credential on our side (401 THIRD_PARTY_AUTH_ERROR), quota or
// server errors, keeps the token.

export function deadPushToken(status, bodyText) {
  let body = null;
  try {
    body = JSON.parse(String(bodyText || ""));
  } catch {
    body = null;
  }
  const error = body?.error || {};
  const details = Array.isArray(error.details) ? error.details : [];
  const codes = new Set(details.map((d) => String(d?.errorCode || "")).filter(Boolean));
  if (codes.has("UNREGISTERED")) return true;
  if (codes.has("THIRD_PARTY_AUTH_ERROR") || codes.has("QUOTA_EXCEEDED") || codes.has("UNAVAILABLE") || codes.has("INTERNAL")) return false;
  if (Number(status) === 404) return true;
  const message = String(error.message || "");
  if (Number(status) === 400 && codes.has("INVALID_ARGUMENT") && /registration token/i.test(message)) return true;
  if (Number(status) === 400 && /not a valid FCM registration token/i.test(message)) return true;
  return false;
}
