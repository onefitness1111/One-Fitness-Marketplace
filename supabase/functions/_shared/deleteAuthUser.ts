// Unchanged copy of the live account-deletion helper.
// deno-lint-ignore-file no-explicit-any

export type AuthDeleteResult = {
  ok: boolean;
  via: "admin-api" | "fallback" | "none";
  apiStatus?: number;
  apiDetail?: string;
  fallbackError?: string;
};

export async function deleteAuthUser(
  admin: any,
  userId: string,
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<AuthDeleteResult> {
  let apiStatus: number | undefined;
  let apiDetail: string | undefined;
  try {
    const res = await fetch(`${supabaseUrl}/auth/v1/admin/users/${userId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${serviceRoleKey}`, apikey: serviceRoleKey },
    });
    if (res.ok) return { ok: true, via: "admin-api" };

    apiStatus = res.status;
    apiDetail = (await res.text().catch(() => "")).slice(0, 500);
    console.error(`deleteAuthUser: admin API ${res.status} for ${userId}: ${apiDetail}`);
  } catch (e) {
    apiDetail = e instanceof Error ? e.message : String(e);
    console.error(`deleteAuthUser: admin API threw for ${userId}: ${apiDetail}`);
  }

  const { error } = await admin.rpc("admin_delete_auth_user", { p_user: userId });
  if (!error) {
    console.warn(`deleteAuthUser: admin API failed for ${userId}; removed directly instead.`);
    return { ok: true, via: "fallback", apiStatus, apiDetail };
  }

  console.error(`deleteAuthUser: fallback also failed for ${userId}: ${error.message}`);
  return { ok: false, via: "none", apiStatus, apiDetail, fallbackError: error.message };
}

export function authDeleteErrorMessage(result: AuthDeleteResult): string {
  const reason = result.fallbackError || result.apiDetail || "no further detail";
  return `Couldn't delete that account: ${reason}`;
}
