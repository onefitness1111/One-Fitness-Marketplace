// Is this request the database's own timer (pg_cron)?
//
// The timer sends x-cron-secret. Every job reads it from Vault through
// public.cron_vault_secret() (secret "apply_requests_cron"). The older
// CRON_SECRET function secret is still accepted so a deploy before the
// cron migration keeps working. Neither value is ever logged.

// deno-lint-ignore no-explicit-any
export async function isCronRequest(admin: any, req: Request): Promise<boolean> {
  const sent = req.headers.get("x-cron-secret") ?? "";
  if (!sent) return false;
  const legacy = Deno.env.get("CRON_SECRET") ?? "";
  if (legacy && sent === legacy) return true;
  try {
    const { data, error } = await admin.rpc("cron_vault_secret");
    if (error) {
      console.error("cron vault read failed");
      return false;
    }
    return typeof data === "string" && data.length > 0 && sent === data;
  } catch {
    return false;
  }
}
