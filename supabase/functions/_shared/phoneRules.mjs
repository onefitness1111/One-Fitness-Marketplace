// Which phone numbers can get a text. No database and no Twilio.
//
// US and Canadian numbers must be real North American numbers: a 10-digit
// number whose area code and exchange start with 2-9. That alone skips the
// made-up test numbers on file (Twilio error 21211), without listing anyone's
// number in code. Numbers Twilio later reports as unreachable are flagged in
// the database (profiles.sms_undeliverable_at) and skipped by the sender.

const NANP = /^[2-9]\d{2}[2-9]\d{6}$/;

/** E.164 for a number that can be texted, or null. */
export function textableNumber(raw) {
  const text = String(raw ?? "").trim();
  if (!text) return null;
  const digits = text.replace(/\D/g, "");
  if (text.startsWith("+") && !text.startsWith("+1")) {
    return digits.length >= 8 && digits.length <= 15 ? `+${digits}` : null;
  }
  let national = digits;
  if (national.length === 11 && national.startsWith("1")) national = national.slice(1);
  if (national.length !== 10) return null;
  if (!NANP.test(national)) return null;
  if (/^(\d)\1{9}$/.test(national)) return null;
  // 555-0100 through 555-0199 are reserved for fiction.
  if (national.slice(3, 6) === "555" && national.slice(6, 8) === "01") return null;
  return `+1${national}`;
}

/** Last four digits, for a log line. Never the whole number. */
export function phoneTail(raw) {
  const digits = String(raw ?? "").replace(/\D/g, "");
  return digits.slice(-4);
}

/** Twilio error codes that mean this number will not get our texts. */
export const TWILIO_OPTED_OUT = new Set([21610]);
export const TWILIO_UNDELIVERABLE = new Set([21211, 21612, 21614, 30005, 30006]);
