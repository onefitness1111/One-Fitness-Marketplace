// The filing program generation is allowed to read.
//
// The current answers sit on the intake entry. Earlier filings live under
// `history`, or on a row whose archived_at is set. Neither is an answer
// the program should follow.

export function currentIntake(record) {
  const raw = record?.intake;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const out = {};
  for (const [key, entry] of Object.entries(raw)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    if (entry.archivedAt || entry.archived_at) continue;
    const rest = { ...entry };
    delete rest.history;
    out[key] = rest;
  }
  return out;
}

// Newest row that has not been archived.
export function primarySubmission(rows) {
  const open = (rows || []).filter((row) => !row?.archived_at && !row?.archivedAt);
  open.sort((a, b) =>
    String(b.created_at || b.completed_at || b.at || "").localeCompare(
      String(a.created_at || a.completed_at || a.at || ""),
    ),
  );
  return open[0] || null;
}

// Current JSON, then any open table rows on top. A table that is not there
// yet leaves the JSON the App Store build already writes.
export async function intakeForAi(admin, clientId, record) {
  const intake = currentIntake(record);
  if (!admin || !clientId) return intake;
  try {
    const { data, error } = await admin
      .from("intake_submissions")
      .select("assessment_key, answers, completed, completed_at, completed_by, extra, created_at, archived_at")
      .eq("client_id", clientId)
      .is("archived_at", null)
      .order("created_at", { ascending: false });
    if (error || !data) return intake;
    const seen = new Set();
    for (const row of data) {
      if (seen.has(row.assessment_key)) continue;
      seen.add(row.assessment_key);
      intake[row.assessment_key] = {
        ...(row.extra || {}),
        answers: row.answers || {},
        completed: row.completed !== false,
        at: row.completed_at,
        by: row.completed_by,
      };
    }
  } catch (_) {}
  return intake;
}
