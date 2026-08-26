// Phase 2Q.1 -- Mobile Document Scanner: multi-page PDF assembly.
//
// No new dependency: pdf-lib (^1.17.1) was already a project dependency
// before this phase (used by invoices/settlements/statements/W-9/broker
// packet PDF generation, see src/lib/*/pdf.ts and
// src/lib/broker-packets/generate.ts). This module only adds a new,
// narrow entry point -- "embed N already-compressed JPEG pages into one
// PDF, one image per page, page size == image size" -- nothing else in
// the codebase already does that (the existing generators all draw text
// onto pages they create themselves).
//
// Runs entirely in the browser (this file has no server-only imports),
// so the scanner can assemble the PDF client-side and hand the caller a
// finished File -- the file then flows through the SAME upload action any
// other PDF would (see document-scanner.tsx's header comment).
import { PDFDocument } from "pdf-lib";

export type ScannedPage = {
  id: string;
  blob: Blob; // always image/jpeg -- see document-scanner.tsx's toProcessedBlob()
  width: number;
  height: number;
};

// Points-per-pixel at a nominal 150 DPI equivalent. The source pixels are
// already the enhanced/compressed output (see MAX_WORKING_DIMENSION in
// document-scanner.tsx), so this only controls the PDF's reported page
// size/DPI metadata, not image quality -- 150dpi keeps an 8.5x11 page's
// PDFPage object at a normal, printable size instead of a huge one that
// some viewers scale oddly.
const POINTS_PER_PIXEL = 72 / 150;

// Combines already-cropped/rotated/enhanced page images (in order) into a
// single PDF, one page per image, sized to that image's aspect ratio.
// Never re-compresses the JPEG bytes themselves -- each page's quality was
// already fixed when it was captured, so assembling multiple pages cannot
// make any single page any blurrier than it already was.
export async function assembleScannedPdf(pages: ScannedPage[]): Promise<Blob> {
  if (pages.length === 0) throw new Error("No pages to assemble.");
  const pdfDoc = await PDFDocument.create();
  for (const page of pages) {
    const bytes = new Uint8Array(await page.blob.arrayBuffer());
    const jpg = await pdfDoc.embedJpg(bytes);
    const pageWidth = page.width * POINTS_PER_PIXEL;
    const pageHeight = page.height * POINTS_PER_PIXEL;
    const pdfPage = pdfDoc.addPage([pageWidth, pageHeight]);
    pdfPage.drawImage(jpg, { x: 0, y: 0, width: pageWidth, height: pageHeight });
  }
  const bytes = await pdfDoc.save();
  // pdf-lib's .save() returns a Uint8Array typed against a generic
  // ArrayBufferLike, which the DOM lib's BlobPart no longer structurally
  // accepts as of newer TypeScript/lib.dom versions -- the underlying
  // bytes are a real ArrayBuffer at runtime (pdf-lib never backs this
  // with a SharedArrayBuffer), so this is a type-level cast only, not a
  // behavior change.
  return new Blob([bytes as unknown as ArrayBuffer], { type: "application/pdf" });
}

// Safe, bounded filename shared by every scan output (image or PDF) --
// same sanitization rule already used by every upload action in the
// codebase (strip to a safe charset, cap length), applied here too since
// the scanner generates its own default name rather than a browser-
// supplied one. Section I: "bounded filenames."
export function scannedFileName(documentLabel: string | undefined, extension: "jpg" | "pdf"): string {
  const base = (documentLabel || "scan").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "scan";
  return `${base}-${Date.now()}.${extension}`;
}
