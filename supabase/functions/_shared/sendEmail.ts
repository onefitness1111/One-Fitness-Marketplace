// Unchanged copy of the live helper, included so send-email and client-notify
// can be deployed from this folder. Delivery is Microsoft Graph, not SMTP.
const TOKEN_HOST = "https://login.microsoftonline.com";
const GRAPH = "https://graph.microsoft.com/v1.0";

let cachedToken: { value: string; expiresAt: number } | null = null;

export function emailFrom(): string {
  return Deno.env.get("EMAIL_FROM") || Deno.env.get("SMTP_USER") || "";
}

async function graphToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedToken.expiresAt) return cachedToken.value;

  const tenant = Deno.env.get("MS_TENANT_ID");
  const clientId = Deno.env.get("MS_CLIENT_ID");
  const clientSecret = Deno.env.get("MS_CLIENT_SECRET");
  if (!tenant || !clientId || !clientSecret) {
    throw new Error("MS_TENANT_ID / MS_CLIENT_ID / MS_CLIENT_SECRET are not configured as function secrets.");
  }

  const res = await fetch(`${TOKEN_HOST}/${tenant}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      scope: "https://graph.microsoft.com/.default",
      grant_type: "client_credentials",
    }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Microsoft token request failed (${res.status}): ${body}`);

  const json = JSON.parse(body) as { access_token: string; expires_in: number };
  cachedToken = { value: json.access_token, expiresAt: Date.now() + (json.expires_in - 60) * 1000 };
  return cachedToken.value;
}

export async function sendEmailOrThrow(to: string, subject: string, text: string): Promise<void> {
  const from = emailFrom();
  if (!from) throw new Error("No sender address configured (set EMAIL_FROM or SMTP_USER).");
  if (!to) throw new Error("No recipient given.");

  const token = await graphToken();
  const res = await fetch(`${GRAPH}/users/${encodeURIComponent(from)}/sendMail`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        subject,
        body: { contentType: "Text", content: text },
        toRecipients: [{ emailAddress: { address: to } }],
      },
      saveToSentItems: true,
    }),
  });
  if (!res.ok) throw new Error(`Microsoft Graph sendMail failed (${res.status}): ${await res.text()}`);
}

export async function sendEmail(to: string, subject: string, text: string): Promise<void> {
  if (!to) return;
  try {
    await sendEmailOrThrow(to, subject, text);
  } catch (e) {
    console.error(`sendEmail: ${e instanceof Error ? e.message : String(e)}`);
  }
}
