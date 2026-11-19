// Pure pieces of the session calendar feed. The edge function adds the
// database reads. These stay free of Supabase so the rules can be tested.

export const DEFAULT_TIME_ZONE = "America/Los_Angeles";
export const CACHE_CONTROL = "private, max-age=900";

/// The owner account has no calendar. Clients and coaches do.
export function calendarSyncAllowed(role) {
  return role === "client" || role === "coach";
}

export function businessTimeZone(data) {
  const workouts = data?.workouts;
  return workouts?.businessTimeZone || data?.businessTimeZone || DEFAULT_TIME_ZONE;
}

export function sessionMinutes(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 60;
}

/// A client sees the public coach name. A legal name is never accepted here.
export function coachLabelForClient(coachPublicName) {
  const label = String(coachPublicName ?? "").trim();
  return label || "Your coach";
}

/// Staff see the client's name. The owner feed uses this same path.
export function clientLabelForStaff(clientName) {
  return String(clientName ?? "").trim();
}

export function icsStamp(d) {
  return new Date(d).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

export function eventRevision(updatedAt) {
  const parsed = updatedAt ? new Date(updatedAt) : null;
  const ms = parsed && !Number.isNaN(parsed.getTime()) ? parsed.getTime() : 0;
  return {
    lastModified: ms ? icsStamp(new Date(ms)) : null,
    sequence: ms ? Math.floor(ms / 1000) : 0,
  };
}

export function esc(s) {
  return String(s ?? "")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

/// RFC 5545: a line is at most 75 octets. Continuations start with a space,
/// and that space counts. A code point is never split across a fold.
export function fold(line) {
  const bytes = new TextEncoder().encode(String(line));
  if (bytes.length <= 75) return String(line);
  const decoder = new TextDecoder();
  const parts = [];
  let i = 0;
  let budget = 75;
  while (i < bytes.length) {
    let end = Math.min(i + budget, bytes.length);
    while (end > i && (bytes[end] & 0xc0) === 0x80) end -= 1;
    if (end === i) {
      end = i + 1;
      while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end += 1;
    }
    const chunk = decoder.decode(bytes.subarray(i, end));
    parts.push(i === 0 ? chunk : ` ${chunk}`);
    i = end;
    budget = 74;
  }
  return parts.join("\r\n");
}

export function foldedLineOctets(folded) {
  return folded.split("\r\n").map((part) => new TextEncoder().encode(part).length);
}

function tzOffsetMs(date, tz) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date).reduce((acc, p) => {
    if (p.type !== "literal") acc[p.type] = p.value;
    return acc;
  }, {});
  const hour = parts.hour === "24" ? 0 : Number(parts.hour);
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    hour,
    Number(parts.minute),
    Number(parts.second),
  );
  return asUtc - date.getTime();
}

export function wallTimeToUtc(dateIso, minutesFromMidnight, tz) {
  const [y, m, d] = dateIso.split("-").map(Number);
  const hh = Math.floor(minutesFromMidnight / 60);
  const mm = minutesFromMidnight % 60;
  const naive = Date.UTC(y, m - 1, d, hh, mm, 0);
  const firstPass = new Date(naive - tzOffsetMs(new Date(naive), tz));
  return new Date(naive - tzOffsetMs(firstPass, tz));
}
