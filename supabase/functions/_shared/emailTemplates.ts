// Database-driven automation emails. Subject, body and the on/off switch live
// in public.email_templates (edited by the owner in Customize Platform), so a
// change applies on the very next send with no deploy.
//
// Body syntax: plain text, {{variable}} tokens, and one optional repeating
// block for emails that list sessions:
//     {{#each sessions}} ... {{/each}}
// The text is turned into the branded ONE Fitness HTML shell here.

// deno-lint-ignore no-explicit-any
type Admin = any;

export type Template = { key: string; enabled: boolean; subject: string; body: string };

const GOLD = "#D4AF37";
const INK = "#0B0B0B";

export const BUSINESS_NAME_FALLBACK = "ONE Fitness Marketplace";

const esc = (s: unknown) =>
  String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export async function loadTemplate(admin: Admin, key: string): Promise<Template | null> {
  const { data } = await admin.from("email_templates").select("key, enabled, subject, body").eq("key", key).maybeSingle();
  return (data as Template | null) ?? null;
}

/// The business name from platform settings, falling back to the brand name.
export async function businessName(admin: Admin): Promise<string> {
  const { data } = await admin.from("platform_settings").select("data").eq("id", "global").maybeSingle();
  const n = (data?.data as Record<string, Record<string, unknown>> | null)?.workouts?.businessName;
  return typeof n === "string" && n.trim() ? n.trim() : BUSINESS_NAME_FALLBACK;
}

const TOKEN = /\{\{\s*([a-zA-Z_]+)\s*\}\}/g;

export function fill(text: string, vars: Record<string, string>): string {
  return text.replace(TOKEN, (m, k: string) => (k in vars ? vars[k] : m));
}

const BLOCK = /\{\{#each sessions\}\}([\s\S]*?)\{\{\/each\}\}/;

/// Plain text -> HTML paragraphs. A blank line starts a new paragraph; single
/// line breaks stay line breaks. ALL-CAPS lines read as small headings.
function textToHtml(text: string): string {
  return text
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0)
    .map((p) => {
      const lines = p.split("\n").map((l) => l.trim());
      const isHeading = lines.length >= 1 && /^[A-Z0-9 ,'&!.\-—]{6,}$/.test(lines[0]) && lines[0] === lines[0].toUpperCase() &&
        /[A-Z]/.test(lines[0]);
      const html = lines.map((l, i) =>
        i === 0 && isHeading
          ? `<span style="color:${GOLD};font-weight:700;letter-spacing:1px;font-size:13px;">${esc(l)}</span>`
          : esc(l)
      ).join("<br>");
      return `<div style="font-size:15px;color:#e0e0e0;line-height:1.55;margin:0 0 14px 0;">${html}</div>`;
    })
    .join("");
}

/// One session's lines, rendered as a card row (first line prominent).
function sessionHtml(text: string): string {
  const lines = text.split("\n").map((l) => l.trim()).filter((l) => l.length > 0);
  if (lines.length === 0) return "";
  const [first, ...rest] = lines;
  return `<div style="padding:12px 0;border-bottom:1px solid #2a2a2a;">
    <div style="font-size:16px;font-weight:700;color:#ffffff;">${esc(first)}</div>
    ${rest.map((l) => `<div style="font-size:14px;color:#cfcfcf;margin-top:2px;">${esc(l)}</div>`).join("")}
  </div>`;
}

export function renderEmail(opts: {
  template: Template;
  vars: Record<string, string>;
  sessions?: Record<string, string>[];
  business: string;
}): { subject: string; html: string } {
  const { template, vars, sessions, business } = opts;
  const subject = fill(template.subject, vars).replace(/\s+/g, " ").trim();

  const m = BLOCK.exec(template.body);
  let bodyHtml: string;
  if (m && sessions) {
    const before = template.body.slice(0, m.index);
    const after = template.body.slice(m.index + m[0].length);
    const blockHtml = sessions.map((s) => sessionHtml(fill(fill(m[1], s), vars))).join("");
    bodyHtml = textToHtml(fill(before, vars)) +
      `<div style="margin:0 0 14px 0;border-top:1px solid #2a2a2a;">${blockHtml}</div>` +
      textToHtml(fill(after, vars));
  } else {
    bodyHtml = textToHtml(fill(template.body.replace(BLOCK, ""), vars));
  }

  const html = `<!doctype html><html><body style="margin:0;background:#000;font-family:Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#000;padding:24px 12px;"><tr><td align="center">
  <table role="presentation" width="560" cellspacing="0" cellpadding="0" style="max-width:560px;width:100%;background:${INK};border:1px solid #2a2a2a;border-radius:14px;overflow:hidden;">
    <tr><td style="padding:22px 28px;background:#000;border-bottom:3px solid ${GOLD};">
      <div style="font-size:22px;font-weight:800;letter-spacing:3px;color:${GOLD};">ONE FITNESS</div>
      <div style="font-size:11px;letter-spacing:2px;color:#9a9a9a;margin-top:2px;">${esc(business.toUpperCase())}</div>
    </td></tr>
    <tr><td style="padding:28px;">${bodyHtml}</td></tr>
  </table>
</td></tr></table></body></html>`;
  return { subject, html };
}
