// Unchanged copy of the live helper.
async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// deno-lint-ignore no-explicit-any
export async function assertPlanContractSigned(
  admin: any,
  profileId: string,
  planId: string,
  opts: { staffPurchasingForClient?: boolean } = {},
): Promise<void> {
  if (opts.staffPurchasingForClient) return;
  const { data: docRows } = await admin.from("waiver_docs").select("id, data");
  const contracts = (docRows ?? [])
    // deno-lint-ignore no-explicit-any
    .map((r: any) => ({ id: r.id, ...(r.data ?? {}) }))
    // deno-lint-ignore no-explicit-any
    .filter((d: any) => d.scope === "plan" && d.planId === planId && d.archived !== true && d.required !== false);
  if (contracts.length === 0) return;

  const { data: sigs } = await admin.from("waiver_signatures")
    .select("doc_id, document_version_hash").eq("client_id", profileId);

  for (const c of contracts) {
    const currentHash = await sha256Hex(String(c.body ?? ""));
    // deno-lint-ignore no-explicit-any
    const signed = (sigs ?? []).some((s: any) => s.doc_id === c.id && s.document_version_hash === currentHash);
    if (!signed) {
      throw new Error(`contract-required: Please read and sign "${c.title ?? "the plan agreement"}" before buying this plan.`);
    }
  }
}
