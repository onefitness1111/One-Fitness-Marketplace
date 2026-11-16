// URLs Twilio may have signed when it called an Edge Function.
//
// Inside the Supabase Edge runtime, req.url is often http and the pathname
// is only "/<function-name>" — the public "/functions/v1" prefix is added
// by the gateway, and that public URL is what Twilio signed. None of the
// raw request URLs match, so every inbound text was rejected with 403.

export interface WebhookUrlInput {
  requestUrl: string;
  forwardedHost: string | null;
  host: string | null;
  /** TWILIO_WEBHOOK_URL, when set. Checked before every other candidate. */
  override: string | null;
  supabaseUrl: string | null;
}

export function webhookCandidates(input: WebhookUrlInput): string[] {
  const requested = new URL(input.requestUrl);
  const rawHost = (input.forwardedHost ?? input.host ?? requested.host).split(",")[0].trim();
  const host = rawHost || requested.host;
  const parts = requested.pathname.split("/").filter(Boolean);
  const functionName = parts[parts.length - 1] ?? "";
  const search = requested.search;

  const ordered: string[] = [];
  const push = (url: string) => {
    if (url && !ordered.includes(url)) ordered.push(url);
  };

  const override = input.override?.trim();
  if (override) push(override);

  if (functionName) {
    push(`https://${host}/functions/v1/${functionName}${search}`);
    push(`https://${host}/functions/v1/${functionName}`);
    if (requested.host && requested.host !== host) {
      push(`https://${requested.host}/functions/v1/${functionName}${search}`);
      push(`https://${requested.host}/functions/v1/${functionName}`);
    }
    if (input.supabaseUrl) {
      try {
        const origin = new URL(input.supabaseUrl).origin;
        push(`${origin}/functions/v1/${functionName}${search}`);
        push(`${origin}/functions/v1/${functionName}`);
      } catch {
        // A bad SUPABASE_URL must not fail the webhook.
      }
    }
  }

  push(input.requestUrl);
  push(`https://${host}${requested.pathname}${search}`);
  push(`https://${host}${requested.pathname}`);
  push(`https://${requested.host}${requested.pathname}${search}`);
  push(`https://${requested.host}${requested.pathname}`);
  return ordered;
}

/**
 * Twilio's webhook signature: HMAC-SHA1 of the URL plus each POST field
 * appended in sorted name order, then base64. The token is the Auth Token.
 * https://www.twilio.com/docs/usage/security#validating-requests
 */
export async function twilioSignature(token: string, url: string, params: Record<string, string>): Promise<string> {
  let payload = url;
  for (const key of Object.keys(params).sort()) payload += key + params[key];
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(token),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(payload));
  let binary = "";
  const bytes = new Uint8Array(mac);
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

export async function twilioSignatureMatches(
  token: string,
  url: string,
  params: Record<string, string>,
  signature: string,
): Promise<boolean> {
  if (!token || !signature) return false;
  const expected = await twilioSignature(token, url, params);
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

/** Safe to log: scheme, host, and path. Query strings and tokens stay out. */
export function describeWebhookUrl(url: string, override: string | null): string {
  if (override && url === override.trim()) return "TWILIO_WEBHOOK_URL";
  try {
    const parsed = new URL(url);
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return "unparsed-url";
  }
}
