// Turns a client's intake attachments into Claude content blocks.
//
// Clients attach bloodwork, a physio's letter, a programme they're already
// on. Those are exactly the things a coach would read before writing a plan,
// so the drafter reads them too — as native content blocks, not as a
// description of a file: a PDF goes in as a `document`, an image as an
// `image`, and plain text inline. Claude reads each directly.
//
// Shapes per the Claude API docs: a base64 `document` block takes
// `{type, source: {type: "base64", media_type, data}}`, an `image` block the
// same with an image media type, and both must precede the text block in the
// same user message.

// deno-lint-ignore no-explicit-any
type AnyRecord = any;

const BUCKET = "intake-files";

/** Media types the bucket accepts, and how each one reaches Claude. */
const AS_DOCUMENT = new Set(["application/pdf"]);
const AS_IMAGE = new Set(["image/jpeg", "image/png"]);
const AS_TEXT = new Set(["text/plain"]);

/**
 * How much attachment content one request may carry, in raw bytes.
 *
 * The Messages API caps a request at 32MB, and base64 inflates by about a
 * third — so 15MB of files is roughly 20MB on the wire, leaving comfortable
 * room for the prompt, the exercise catalogue and the schema. The bucket
 * allows 10MB per file and six files per form across two forms, so without a
 * budget a client could assemble 120MB and every generation would fail with
 * a request-too-large error that named nothing useful.
 */
const MAX_TOTAL_BYTES = 15 * 1024 * 1024;

/** A single file is skipped above this, rather than eating the whole budget. */
const MAX_ONE_BYTES = 10 * 1024 * 1024;

/** Plain text is inlined, so it is capped far lower — this is prompt, not a file. */
const MAX_TEXT_CHARS = 20000;

export type AttachmentBlocks = {
  // deno-lint-ignore no-explicit-any
  blocks: any[];
  /** Names of files that were read, for the prompt's own framing. */
  included: string[];
  /** Name plus reason for anything left out, so it can be logged. */
  skipped: string[];
};

function toBase64(bytes: Uint8Array): string {
  // btoa on a large string blows the call stack via String.fromCharCode(...),
  // so build it in chunks.
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/**
 * Downloads the attachments recorded on [record].intake[key] and converts
 * them. Never throws: a file that has gone missing, or a download that
 * fails, costs that one attachment rather than the whole program draft —
 * a coach waiting on a plan is better served by a draft built from the
 * answers alone than by an error.
 */
export async function buildAttachmentBlocks(
  // deno-lint-ignore no-explicit-any
  admin: any,
  record: AnyRecord,
  assessmentKeys: string[],
): Promise<AttachmentBlocks> {
  // deno-lint-ignore no-explicit-any
  const blocks: any[] = [];
  const included: string[] = [];
  const skipped: string[] = [];
  let budget = MAX_TOTAL_BYTES;

  for (const key of assessmentKeys) {
    const entry = record?.intake?.[key];
    const attachments = Array.isArray(entry?.attachments) ? entry.attachments : [];
    for (const a of attachments) {
      const path = typeof a?.path === "string" ? a.path : "";
      const name = typeof a?.name === "string" && a.name ? a.name : "attachment";
      const mediaType = typeof a?.contentType === "string" ? a.contentType : "";
      if (!path) {
        skipped.push(`${name} (no stored file)`);
        continue;
      }
      const size = Number(a?.size ?? 0);
      if (size > MAX_ONE_BYTES) {
        skipped.push(`${name} (too large)`);
        continue;
      }

      let bytes: Uint8Array;
      try {
        const { data, error } = await admin.storage.from(BUCKET).download(path);
        if (error || !data) {
          skipped.push(`${name} (couldn't be read)`);
          continue;
        }
        bytes = new Uint8Array(await data.arrayBuffer());
      } catch (_) {
        skipped.push(`${name} (couldn't be read)`);
        continue;
      }

      if (bytes.byteLength > budget) {
        skipped.push(`${name} (over the per-request limit)`);
        continue;
      }

      if (AS_TEXT.has(mediaType)) {
        const text = new TextDecoder().decode(bytes).slice(0, MAX_TEXT_CHARS);
        if (!text.trim()) {
          skipped.push(`${name} (empty)`);
          continue;
        }
        blocks.push({ type: "text", text: `--- Client attachment: ${name} ---\n${text}` });
      } else if (AS_DOCUMENT.has(mediaType)) {
        blocks.push({
          type: "document",
          source: { type: "base64", media_type: mediaType, data: toBase64(bytes) },
        });
      } else if (AS_IMAGE.has(mediaType)) {
        blocks.push({
          type: "image",
          source: { type: "base64", media_type: mediaType, data: toBase64(bytes) },
        });
      } else {
        // The bucket's allowed list and this one are supposed to match; if
        // they drift, say so rather than sending a block Claude rejects.
        skipped.push(`${name} (unsupported type ${mediaType || "unknown"})`);
        continue;
      }

      budget -= bytes.byteLength;
      included.push(name);
    }
  }

  return { blocks, included, skipped };
}
