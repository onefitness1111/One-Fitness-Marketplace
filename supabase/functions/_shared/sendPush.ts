// Unchanged copy of the live Firebase Cloud Messaging helper.
// Best-effort: a missing Firebase secret or a bad token never fails the caller.
interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----BEGIN PRIVATE KEY-----/, "").replace(/-----END PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const enc = (obj: unknown) => base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(obj)));
  const unsigned = `${enc(header)}.${enc(claims)}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${base64UrlFromBytes(new Uint8Array(signature))}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) throw new Error(`FCM auth failed: ${JSON.stringify(data)}`);
  return data.access_token as string;
}

async function withoutOptedOut(tokens: string[]): Promise<string[]> {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key || tokens.length === 0) return tokens;
  try {
    const headers = { apikey: key, Authorization: `Bearer ${key}` };
    const list = tokens.map((t) => `"${t.replace(/"/g, "")}"`).join(",");
    const rows: { token: string; profile_id: string }[] =
      await (await fetch(`${url}/rest/v1/device_tokens?select=token,profile_id&token=in.(${encodeURIComponent(list)})`, { headers })).json();
    const ids = [...new Set(rows.map((r) => r.profile_id))];
    if (ids.length === 0) return tokens;
    const muted: { id: string }[] =
      await (await fetch(`${url}/rest/v1/profiles?select=id&push_opt_in=eq.false&id=in.(${ids.join(",")})`, { headers })).json();
    if (!Array.isArray(muted) || muted.length === 0) return tokens;
    const mutedIds = new Set(muted.map((m) => m.id));
    const mutedTokens = new Set(rows.filter((r) => mutedIds.has(r.profile_id)).map((r) => r.token));
    return tokens.filter((t) => !mutedTokens.has(t));
  } catch (e) {
    console.error("sendPush: opt-out lookup failed:", e instanceof Error ? e.message : String(e));
    return tokens;
  }
}

export async function sendPush(allTokens: string[], title: string, body: string, data?: Record<string, string>): Promise<void> {
  const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
  if (!raw || allTokens.length === 0) return;
  const tokens = await withoutOptedOut(allTokens);
  if (tokens.length === 0) return;

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(raw);
  } catch {
    console.error("sendPush: FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON");
    return;
  }

  let accessToken: string;
  try {
    accessToken = await getAccessToken(sa);
  } catch (e) {
    console.error("sendPush: couldn't get an access token:", e instanceof Error ? e.message : String(e));
    return;
  }

  for (const token of tokens) {
    try {
      const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message: { token, notification: { title, body }, data: data ?? {} } }),
      });
      if (!res.ok) console.error(`sendPush: send failed for token …${token.slice(-6)} (${res.status}): ${await res.text()}`);
    } catch (e) {
      console.error(`sendPush: send error for token …${token.slice(-6)}:`, e instanceof Error ? e.message : String(e));
    }
  }
}
