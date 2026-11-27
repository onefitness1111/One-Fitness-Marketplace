// The one name the business (the owner) goes by, in chat, texts and emails.
// Coach Chris picked "ONE Fitness Marketplace" (Nov 27, 2026). Change it
// here only. The app's copy is kMarketplaceName in
// lib/core/utils/chat_channels.dart, and the database label is
// public.business_display_name().

export const OWNER_DISPLAY_NAME = "ONE Fitness Marketplace";

/** Prefix on every automatic text the business sends. */
export const SMS_PREFIX = `${OWNER_DISPLAY_NAME}: `;

/** Sign-off line on plain-text emails. */
export const EMAIL_SIGNOFF = `— ${OWNER_DISPLAY_NAME}`;

/** Adds the business prefix once. A text that already starts with it is left alone. */
export function businessText(text) {
  const body = String(text ?? "").trim();
  if (body.startsWith(SMS_PREFIX.trim())) return body;
  return `${SMS_PREFIX}${body}`;
}
