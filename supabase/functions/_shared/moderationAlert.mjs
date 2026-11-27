// The owner's alert for a new report or block. Category words only; never
// a name, phone, email, or the reported text.

const CLEAN = /[^a-z0-9 ,_-]/gi;

export function moderationAlert({ kind, category, openReports }) {
  const open = Number(openReports) || 0;
  const openLine = `Open reports: ${open}.`;
  if (kind === "block") {
    return {
      title: "A member blocked someone",
      body: `A member blocked another member. ${openLine}`,
    };
  }
  const what = String(category || "").replace(CLEAN, "").trim().slice(0, 80);
  return {
    title: "A report needs review",
    body: `A member filed a report${what ? ` (${what})` : ""}. Please review it within 24 hours. ${openLine}`,
  };
}
