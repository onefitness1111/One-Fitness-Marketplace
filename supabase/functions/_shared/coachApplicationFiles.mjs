// Labels and the send rules for an Apply now upload. The phone uses the
// same rules in lib/core/utils/coach_application_files.dart.

export const FILE_CAP = 20;
export const LOCATION_PHOTO_CAP = 8;

export const TYPE_OPTIONS = [
  ["certification", "Certification"],
  ["cpr", "CPR"],
  ["degree", "Degree"],
  ["location-approval", "Location approval notice / Owner permission"],
  ["insurance", "Insurance"],
  ["before-after", "Before and after photo"],
  ["location-photo", "Location photo (max 8)"],
];

const CREDENTIALS = ["certification", "cpr", "degree"];

export function applicationUploadError(kinds) {
  const have = new Set(kinds || []);
  if (!CREDENTIALS.some((kind) => have.has(kind))) {
    return "Add at least one certification, CPR card, or degree.";
  }
  if (!have.has("location-approval")) {
    return "Add a location approval notice or owner permission.";
  }
  if (!have.has("insurance")) {
    return "Add proof of insurance.";
  }
  return null;
}

export function applicationAddError({ kind, filesSoFar, locationPhotos }) {
  if (kind === "location-photo" && locationPhotos >= LOCATION_PHOTO_CAP) {
    return "You can add up to 8 location photos.";
  }
  const adding = kind === "before-after" ? 2 : 1;
  if (filesSoFar + adding > FILE_CAP) {
    return "An application can hold up to 20 files.";
  }
  return null;
}

function namesFor(documents, kind) {
  const names = (documents || [])
    .filter((doc) => doc && doc.kind === kind && String(doc.name || "").trim())
    .map((doc) => String(doc.name).trim());
  return names.length ? names.join(", ") : "Not included";
}

export function applicationReviewLines({ documents, beforeAfterPairs, locationPhotoCount }) {
  const pairs = Number(beforeAfterPairs) || 0;
  const locations = Number(locationPhotoCount) || 0;
  return [
    `Certification: ${namesFor(documents, "certification")}`,
    `CPR: ${namesFor(documents, "cpr")}`,
    `Degree: ${namesFor(documents, "degree")}`,
    `Location approval notice / Owner permission: ${namesFor(documents, "location-approval")}`,
    `Insurance: ${namesFor(documents, "insurance")}`,
    `Before and after photo: ${pairs === 0 ? "Not included" : `${pairs} pair${pairs === 1 ? "" : "s"}, side by side`}`,
    `Location photo: ${locations === 0 ? "Not included" : `${locations} of 8`}`,
  ];
}

/// Plain HTML so each before photo sits beside its after photo.
export function applicationEmailHtml(textBody, pairs) {
  const lines = String(textBody)
    .split("\n")
    .map((line) => `<p style="margin:0 0 8px;color:#111;font-family:Arial,sans-serif;font-size:14px;">${escapeHtml(line) || "&nbsp;"}</p>`)
    .join("");
  const frames = (pairs || []).map((pair, index) => `
    <p style="margin:16px 0 6px;color:#111;font-family:Arial,sans-serif;font-size:14px;font-weight:700;">Before and after pair ${index + 1}</p>
    <table role="presentation" cellpadding="0" cellspacing="0"><tr>
      <td style="padding-right:8px;vertical-align:top;">
        <div style="color:#444;font-family:Arial,sans-serif;font-size:12px;margin-bottom:4px;">Before</div>
        <img src="${escapeAttr(pair.beforeUrl)}" alt="Before" width="240" style="display:block;background:#111;border:1px solid #222;">
      </td>
      <td style="vertical-align:top;">
        <div style="color:#444;font-family:Arial,sans-serif;font-size:12px;margin-bottom:4px;">After</div>
        <img src="${escapeAttr(pair.afterUrl)}" alt="After" width="240" style="display:block;background:#111;border:1px solid #222;">
      </td>
    </tr></table>`).join("");
  return `<div style="background:#fff;color:#111;">${lines}${frames}</div>`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll('"', "&quot;");
}
