import "server-only";

export type UploadValidationResult = { ok: true } | { ok: false; error: string };

const PDF_SIGNATURE = Buffer.from("%PDF-", "ascii");
const JPEG_SIGNATURE = Buffer.from([0xff, 0xd8, 0xff]);
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
// HEIC/HEIF is an ISO-BMFF (MP4-family) container: bytes 4-7 are always
// the literal ASCII "ftyp" box-type, and bytes 8-11 are a 4-char brand
// naming the specific format -- "heic"/"heix" (single-image HEIC),
// "hevc"/"hevx" (HEIC image sequence), or "mif1"/"msf1" (the more generic
// HEIF brands some camera/phone encoders emit instead). Checking the box
// type plus this brand allowlist is the real signature check for this
// format (there's no single fixed magic number the way PDF/JPEG/PNG have
// one) -- added for Phase 2L.4's carrier-onboarding document upload,
// which is the first upload path in this app to actually accept HEIC.
const FTYP_BOX = Buffer.from("ftyp", "ascii");
const HEIC_BRANDS = new Set(["heic", "heix", "hevc", "hevx", "mif1", "msf1"]);

function looksLikeHeic(head: Buffer): boolean {
  if (head.length < 12) return false;
  if (!head.subarray(4, 8).equals(FTYP_BOX)) return false;
  const brand = head.subarray(8, 12).toString("ascii");
  return HEIC_BRANDS.has(brand);
}

// Conservative floor, not a precise one: a real minimal single-page PDF
// (even one pdf-lib itself produces) is several hundred bytes at least --
// 100 is comfortably below any genuine PDF while still comfortably above
// "just the 5-byte magic number and nothing else," which is exactly what
// the real file that triggered this investigation turned out to be.
const MIN_PDF_BYTES = 100;

// Verifies a file's ACTUAL bytes match what it claims to be -- never
// trusts the filename extension or the browser-supplied MIME type alone
// (spec: "Do not rely only on filename extension or browser-provided MIME
// type"). Root-caused live: a real production document (pod.pdf, 31
// bytes) was literally the text "%PDF-1.4 fake test pdf content." -- a
// PDF-looking magic number glued onto a plain string, no real PDF
// structure at all -- uploaded with mime_type: "application/pdf" and
// accepted, because nothing had ever looked past that claimed type before
// this. This function is the fix: called at upload time, before the file
// ever reaches Storage or the documents table, for both the PDF and image
// paths (images get the same real-signature check for the same reason,
// not just PDFs -- spec's own item 8 isn't PDF-specific).
export async function validateUploadedFile(file: File): Promise<UploadValidationResult> {
  if (file.size === 0) return { ok: false, error: "The file is empty." };

  const head = Buffer.from(await file.slice(0, 16).arrayBuffer());

  if (file.type === "application/pdf") {
    if (!head.subarray(0, PDF_SIGNATURE.length).equals(PDF_SIGNATURE)) {
      return { ok: false, error: "This file does not look like a real PDF (missing the PDF file signature)." };
    }
    if (file.size < MIN_PDF_BYTES) {
      return { ok: false, error: "This file is too small to be a real PDF." };
    }
    return { ok: true };
  }

  if (file.type === "image/jpeg") {
    if (!head.subarray(0, JPEG_SIGNATURE.length).equals(JPEG_SIGNATURE)) {
      return { ok: false, error: "This file does not look like a real JPEG image." };
    }
    return { ok: true };
  }

  if (file.type === "image/png") {
    if (!head.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
      return { ok: false, error: "This file does not look like a real PNG image." };
    }
    return { ok: true };
  }

  if (file.type === "image/heic" || file.type === "image/heif") {
    if (!looksLikeHeic(head)) {
      return { ok: false, error: "This file does not look like a real HEIC image." };
    }
    return { ok: true };
  }

  // Caller is expected to have already rejected any type outside this set
  // (ALLOWED_TYPES) before reaching here -- this is a defensive fallback,
  // not the primary gate for "unsupported type" messaging.
  return { ok: false, error: "Unsupported file type. Use PDF, JPG, PNG, or HEIC." };
}
