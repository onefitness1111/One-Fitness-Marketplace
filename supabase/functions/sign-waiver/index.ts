// Records one e-signature event on a waiver and produces the signed PDF.
//
// Runs server-side (service role) because everything that has to be
// trusted — which version of the text was in force, the signer's IP, the
// authenticated session, the time — can only be established here. The app
// submits the captures (initials, signature, checkbox taps); this function
// re-derives every merge-token value from the database itself, validates
// completeness, builds the PDF with a completion certificate, emails it to
// the client, and writes one immutable row to `waiver_signatures` (see
// migration/03_waiver_signatures.sql — nothing but this function can
// insert there, and no one can edit a row afterwards).
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import { sendEmail } from "../_shared/sendEmail.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

/// The five clauses every waiver is initialled against, in order. Keep in
/// sync with kWaiverClauses in lib/core/utils/merge_token_utils.dart.
const CLAUSES = [
  { key: "assumption_of_risk", title: "Assumption of Risk", text: "I understand that physical training carries an inherent risk of injury, and I voluntarily accept those risks." },
  { key: "release_of_liability", title: "Release of Liability", text: "I release ONE Fitness, its owners, coaches and staff from liability for injury or loss arising from my participation, except where caused by gross negligence." },
  { key: "medical_disclosure", title: "Medical Disclosure", text: "I have disclosed any medical condition that may affect my training, and I will tell my coach promptly if my health changes." },
  { key: "no_refund", title: "No Refund Policy", text: "I understand that memberships, packages and sessions are non-refundable once purchased." },
  { key: "late_cancellation", title: "Late Cancellation / No-Show Policy", text: "I understand that late cancellations and no-shows may be charged a fee and that a no-show forfeits the session." },
];

const STRUCTURAL_RE = /\{\{\s*(initial|signature|guardian_signature|photo_opt_out)\s*\}\}/g;
const TOKEN_RE = /\{\{\s*([a-zA-Z_]+)\s*\}\}/g;

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
const sha256Text = (t: string) => sha256Hex(new TextEncoder().encode(t));

function sessionIdFromJwt(authHeader: string | null): string | null {
  const token = authHeader?.replace(/^Bearer /i, "");
  if (!token) return null;
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    return payload.session_id ?? null;
  } catch {
    return null;
  }
}

function ageFromBirthday(birthday: string | null): number | null {
  if (!birthday) return null;
  const dob = new Date(birthday + "T00:00:00");
  if (Number.isNaN(dob.getTime())) return null;
  const now = new Date();
  let age = now.getFullYear() - dob.getFullYear();
  if (now.getMonth() < dob.getMonth() || (now.getMonth() === dob.getMonth() && now.getDate() < dob.getDate())) age--;
  return age;
}

function dataUrlToBytes(dataUrl: string): Uint8Array {
  const bin = atob(dataUrl.split(",").pop() || "");
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// The PDF's standard font (Helvetica, WinAnsi encoding) can't draw tabs,
// emoji or most non-Latin characters, and throws on them. Anything outside
// what it can encode is swapped for a safe equivalent before drawing, so an
// owner pasting a waiver with tabs or symbols can't break signing.
const WINANSI_EXTRA = new Set("€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ".split(""));
function pdfSafe(t: string): string {
  return t
    .replace(/\t/g, "    ")
    .replace(/\r/g, "")
    .replace(/[✓✔☑☒]/g, "[x]")
    .replace(/[☐□]/g, "[ ]")
    .split("")
    .map((ch) => (ch === "\n" || (ch.charCodeAt(0) >= 0x20 && ch.charCodeAt(0) <= 0xff) || WINANSI_EXTRA.has(ch) ? ch : "?"))
    .join("");
}

function isoOrNull(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const receivedAt = new Date().toISOString();
    const body = await req.json();
    const {
      waiverId,
      sections,            // [{key, image, ackAt}] — one per clause, in CLAUSES order
      signatureImage,      // client's signature (not used for a minor)
      signatureMethod,     // "draw" | "type" | "adopted"
      signatureAt,
      guardianName,
      guardianSignatureImage,
      guardianSignedAt,
      photoVideoRelease,   // true = permission granted
      consentAcknowledged,
      consentAt,
      deviceInfo,
      emergencyContactName,
      emergencyContactPhone,
      adoptInitials,       // save sections[0].image as the client's adopted initials
      adoptSignature,      // save signatureImage as the client's adopted signature
    } = body;

    if (!waiverId) throw new Error("waiverId is required.");
    if (consentAcknowledged !== true) throw new Error("Please tick \"I agree to sign electronically\" before signing.");

    const authed = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) throw new Error("Not signed in.");
    const clientId = user.id; // always the caller — nobody signs for someone else

    const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

    const { data: waiverRow } = await admin.from("waiver_docs").select("data").eq("id", waiverId).maybeSingle();
    if (!waiverRow?.data) throw new Error("That document no longer exists.");
    const waiver = waiverRow.data as Record<string, any>;
    if (waiver.archived) throw new Error("That document is no longer active.");

    // ── Clauses: all five, each initialled with its own acknowledgement ──
    const given = Array.isArray(sections) ? sections : [];
    const sectionRecords = CLAUSES.map((c) => {
      const s = given.find((x: any) => x?.key === c.key);
      return {
        key: c.key,
        title: c.title,
        image: typeof s?.image === "string" && s.image.startsWith("data:image") ? s.image : null,
        client_ack_at: isoOrNull(s?.ackAt),
        server_received_at: receivedAt,
      };
    });
    const flags = sectionRecords.map((s) => !!s.image && !!s.client_ack_at);
    const missing = sectionRecords.filter((_, i) => !flags[i]).map((s) => s.title);
    if (missing.length) throw new Error(`Please initial every section — missing: ${missing.join(", ")}.`);

    const [{ data: profile }, { data: clientRow }, { data: recordRow }] = await Promise.all([
      admin.from("profiles").select("name, first_name, last_name, email").eq("id", clientId).maybeSingle(),
      admin.from("clients").select("birthday, emergency_contact_name, emergency_contact_phone").eq("profile_id", clientId).maybeSingle(),
      admin.from("client_records").select("data").eq("profile_id", clientId).maybeSingle(),
    ]);
    if (!profile) throw new Error("Your account couldn't be found.");
    const record = (recordRow?.data as Record<string, any>) || {};

    // ── Minor → guardian signs instead ──
    const age = ageFromBirthday(clientRow?.birthday || null);
    const isMinor = age != null && age < 18;
    if (isMinor) {
      if (!String(guardianName || "").trim() || !guardianSignatureImage) {
        throw new Error("You're under 18, so a parent or legal guardian must enter their name and sign.");
      }
    } else if (!signatureImage) {
      throw new Error("Please sign the document.");
    }

    // ── Emergency contact: sent from the form if it wasn't on file ──
    const intake = record.intake?.personalTraining?.answers || {};
    const ecName = String(emergencyContactName || clientRow?.emergency_contact_name || intake.ecName || "").trim();
    const ecPhone = String(emergencyContactPhone || clientRow?.emergency_contact_phone || intake.ecPhone || "").trim();
    if (!ecName || !ecPhone) throw new Error("An emergency contact name and phone number are required.");

    // Clients are not assigned to a coach (no primary_trainer_id), so the
    // waiver names the business rather than one coach.
    const coachName = "ONE Fitness";

    const fullName = String(profile.name || "").trim();
    const parts = fullName.split(/\s+/);
    const signatureDate = receivedAt.slice(0, 10); // server-generated, never from the app
    const mergeValues: Record<string, string> = {
      client_first_name: String(profile.first_name || parts[0] || ""),
      client_last_name: String(profile.last_name || parts.slice(1).join(" ") || ""),
      client_full_name: fullName,
      client_dob: String(clientRow?.birthday || ""),
      emergency_contact_name: ecName,
      emergency_contact_phone: ecPhone,
      coach_name: coachName,
      signature_date: signatureDate,
      guardian_name: isMinor ? String(guardianName).trim() : "",
      guardian_signature: isMinor ? "[guardian signature below]" : "",
    };

    const rawBody = String(waiver.body || "");
    const documentVersionHash = await sha256Text(rawBody);
    // The owner's waiver marks where each clause is initialled with
    // {{initial_1}} … {{initial_5}}. Those markers are kept in the working
    // text so the PDF can put each clause's actual initials right there;
    // the stored copy says "[initialled]" instead.
    const INITIAL_N_RE = /\{\{\s*initial_(\d+)\s*\}\}/g;
    const hasInlineInitials = INITIAL_N_RE.test(rawBody);
    const optOutBox = photoVideoRelease === true ? "[ ]" : "[X]";
    const workingText = rawBody
      .replace(STRUCTURAL_RE, "")
      .replace(/[☐☑✓✔]\s*I decline/gi, `${optOutBox} I decline`)
      .replace(TOKEN_RE, (whole, key) => (key in mergeValues ? mergeValues[key] : whole))
      .trim();
    const signedBodyText = workingText.replace(INITIAL_N_RE, "[initialled]");

    const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || req.headers.get("cf-connecting-ip") || "unknown";
    const userAgent = req.headers.get("user-agent") || "unknown";
    const sessionId = sessionIdFromJwt(req.headers.get("Authorization"));
    const signerRole = isMinor ? "guardian" : "client";
    const finalSigAt = isoOrNull(isMinor ? guardianSignedAt : signatureAt) || receivedAt;
    const consentAtIso = isoOrNull(consentAt) || receivedAt;

    // ── PDF ──
    const pdf = await PDFDocument.create();
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const margin = 50, W = 612, H = 792;
    let page = pdf.addPage([W, H]);
    let y = H - margin;
    const ensure = (need: number) => {
      if (y - need < margin) {
        page = pdf.addPage([W, H]);
        y = H - margin;
      }
    };
    const line = (t: string, size = 10, f = font, gap = 14, color = rgb(0, 0, 0)) => {
      ensure(gap);
      page.drawText(pdfSafe(t), { x: margin, y, size, font: f, color });
      y -= gap;
    };
    const wrap = (t: string, size = 10, f = font, gap = 13) => {
      const max = W - margin * 2;
      for (const para of pdfSafe(t).split("\n")) {
        if (!para.trim()) { y -= gap * 0.6; continue; }
        let cur = "";
        for (const w of para.split(" ")) {
          const trial = cur ? `${cur} ${w}` : w;
          if (f.widthOfTextAtSize(trial, size) > max && cur) { line(cur, size, f, gap); cur = w; } else cur = trial;
        }
        if (cur) line(cur, size, f, gap);
      }
    };
    const image = async (label: string, dataUrl: string | null, maxW = 180, maxH = 55) => {
      if (!dataUrl) return;
      ensure(maxH + 26);
      line(label, 8.5, bold, 12, rgb(0.25, 0.25, 0.25));
      try {
        const bytes = dataUrlToBytes(dataUrl);
        const img = dataUrl.includes("image/jp") ? await pdf.embedJpg(bytes) : await pdf.embedPng(bytes);
        const s = Math.min(maxW / img.width, maxH / img.height, 1);
        page.drawImage(img, { x: margin, y: y - img.height * s, width: img.width * s, height: img.height * s });
        y -= img.height * s + 10;
      } catch {
        line("[image unavailable]", 9);
      }
    };

    line(String(waiver.title || "Waiver"), 15, bold, 22);
    line(`Signer: ${fullName}${isMinor ? ` (minor — signed by guardian ${mergeValues.guardian_name})` : ""}`, 10, font, 13);
    line(`Date signed: ${signatureDate}`, 10, font, 20);
    if (hasInlineInitials) {
      // Walk the text, dropping each clause's initials in where its marker
      // sits — the signed document reads exactly like the paper version.
      let last = 0;
      for (const m of workingText.matchAll(/\{\{\s*initial_(\d+)\s*\}\}/g)) {
        wrap(workingText.slice(last, m.index));
        const s = sectionRecords[Number(m[1]) - 1];
        if (s) await image(`${s.title} — initialled ${s.client_ack_at}`, s.image, 90, 34);
        last = (m.index ?? 0) + m[0].length;
      }
      wrap(workingText.slice(last));
    } else {
      // A waiver without markers: its text, then the five clauses to initial.
      wrap(workingText);
      y -= 8;
      line("Acknowledgements", 12, bold, 18);
      for (let i = 0; i < CLAUSES.length; i++) {
        const c = CLAUSES[i], s = sectionRecords[i];
        line(`${i + 1}. ${c.title}`, 10.5, bold, 14);
        wrap(c.text, 9.5, font, 12);
        await image(`Initialled ${s.client_ack_at}`, s.image, 90, 34);
      }
    }
    y -= 4;
    line(`Photo/Video Release: ${photoVideoRelease === true ? "GRANTED" : "DECLINED"}`, 10, bold, 18);
    if (isMinor) {
      line(`Parent/Guardian: ${mergeValues.guardian_name}`, 10, font, 14);
      await image(`Guardian signature — ${finalSigAt}`, guardianSignatureImage, 220, 70);
    } else {
      await image(`Client signature — ${finalSigAt}`, signatureImage, 220, 70);
    }

    // Completion certificate
    page = pdf.addPage([W, H]);
    y = H - margin;
    line("Certificate of Completion", 15, bold, 24);
    const certificate: Record<string, string> = {
      "Document": String(waiver.title || ""),
      "Document ID": String(waiverId),
      "Document version hash (SHA-256)": documentVersionHash,
      "Signer": fullName,
      "Signer email": String(profile.email || ""),
      "Signing role": signerRole === "guardian" ? `Parent/guardian (${mergeValues.guardian_name})` : "Client",
      "Consent to sign electronically": consentAtIso,
      "Sections initialled": `${flags.filter(Boolean).length} of ${CLAUSES.length}`,
      "Final signature": finalSigAt,
      "Signature method": String(signatureMethod || "draw"),
      "Photo/Video Release": photoVideoRelease === true ? "Granted" : "Declined",
      "Signer IP address": ip,
      "User agent": userAgent,
      "Device": String(deviceInfo || "unknown"),
      "Session ID": String(sessionId || "unknown"),
      "Recorded by server": receivedAt,
    };
    for (const [k, v] of Object.entries(certificate)) {
      line(k, 8.5, bold, 11, rgb(0.3, 0.3, 0.3));
      wrap(v, 10, font, 16);
    }
    line("Per-section initials", 8.5, bold, 11, rgb(0.3, 0.3, 0.3));
    for (const s of sectionRecords) wrap(`${s.title}: ${s.client_ack_at}`, 9.5, font, 13);

    const pdfBytes = await pdf.save();
    const pdfSha256 = await sha256Hex(pdfBytes);
    let bin = "";
    for (let i = 0; i < pdfBytes.length; i += 8192) bin += String.fromCharCode(...pdfBytes.subarray(i, i + 8192));
    const pdfBase64 = btoa(bin);

    // ── Email a copy to the client (ESIGN) ──
    let emailedTo: string | null = null;
    let emailedAt: string | null = null;
    if (profile.email) {
      await sendEmail(
        String(profile.email),
        `Your signed copy — ${waiver.title}`,
        `Hi ${mergeValues.client_first_name || fullName},\n\nThanks for signing "${waiver.title}". Your signed copy, including the completion certificate, is attached.\n\nYou can also find it any time in the app under Signatures.\n\n— ONE Fitness`,
        [{ name: `${String(waiver.title || "Waiver").replace(/[^\w\- ]+/g, "")}.pdf`, contentType: "application/pdf", base64: pdfBase64 }],
      );
      emailedTo = String(profile.email);
      emailedAt = new Date().toISOString();
    }

    // ── Store: the immutable signature row ──
    const { data: inserted, error: insErr } = await admin.from("waiver_signatures").insert({
      client_id: clientId,
      doc_id: String(waiverId),
      doc_title: String(waiver.title || ""),
      document_version_hash: documentVersionHash,
      signed_body_text: signedBodyText,
      merge_values: mergeValues,
      sections: sectionRecords,
      section_ack_flags: flags,
      signer_role: signerRole,
      signature_image: isMinor ? null : signatureImage,
      signature_method: String(signatureMethod || "draw"),
      signature_at: isMinor ? null : finalSigAt,
      guardian_name: isMinor ? mergeValues.guardian_name : null,
      guardian_signature_image: isMinor ? guardianSignatureImage : null,
      guardian_signed_at: isMinor ? finalSigAt : null,
      photo_video_release: photoVideoRelease === true,
      consent_checkbox_at: consentAtIso,
      consent_recorded_at: receivedAt,
      signer_ip: ip,
      user_agent: userAgent,
      device_info: deviceInfo || null,
      session_id: sessionId,
      pdf_base64: pdfBase64,
      pdf_sha256: pdfSha256,
      certificate,
      emailed_to: emailedTo,
      emailed_at: emailedAt,
    }).select("id, signed_at").single();
    if (insErr) throw insErr;

    // ── Profile updates ──
    await admin.from("clients").update({
      emergency_contact_name: ecName,
      emergency_contact_phone: ecPhone,
      // Release left unticked → excluded from marketing exports.
      marketing_opt_out: photoVideoRelease !== true,
    }).eq("profile_id", clientId);

    // Lightweight summary the app's Signatures list and booking check read;
    // the authoritative record is the waiver_signatures row above.
    const summary = {
      id: inserted.id,
      docId: String(waiverId),
      title: String(waiver.title || ""),
      signedAt: new Date(inserted.signed_at).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }),
      documentVersionHash,
      photoVideoOptOut: photoVideoRelease !== true,
    };
    const nextRecord: Record<string, any> = {
      ...record,
      signatures: [...((record.signatures as any[]) || []).filter((s) => s?.docId !== waiverId), summary],
      photoVideoOptOut: photoVideoRelease !== true,
    };
    if (adoptInitials && sectionRecords[0].image) nextRecord.adoptedInitialsImage = sectionRecords[0].image;
    if (adoptSignature && !isMinor && signatureImage) nextRecord.adoptedSignatureImage = signatureImage;
    if (isMinor) nextRecord.guardianName = mergeValues.guardian_name;
    await admin.from("client_records").upsert({ profile_id: clientId, data: nextRecord });

    console.log(`sign-waiver: ${clientId} signed ${waiverId} (${summary.title}) → ${inserted.id}`);
    return new Response(JSON.stringify({ ok: true, signature: summary, emailedTo }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : (typeof e === "object" && e && "message" in e ? String((e as any).message) : String(e));
    console.error("sign-waiver failed:", message);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
  }
});
