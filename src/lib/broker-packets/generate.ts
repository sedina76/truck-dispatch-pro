import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import { createHash } from "node:crypto";
import {
  DOCUMENT_LABELS,
  MAX_GENERATED_BYTES,
  MAX_PACKAGE_PAGES,
  type BrokerPacketItemRow,
  type BrokerSnapshot,
  type CarrierSnapshot,
  type OrganizationSnapshot,
} from "./types";

// Layout constants and drawing helpers mirror
// src/lib/carrier-setup-packages/generate.ts deliberately (same page size,
// palette, font stack, wrapping/section helpers) -- this is the proven,
// already-shipped renderer pattern for exactly this kind of document.
const LETTER_WIDTH = 612;
const LETTER_HEIGHT = 792;
const MARGIN = 52;
const NAVY = rgb(0.08, 0.16, 0.25);
const SLATE = rgb(0.35, 0.4, 0.47);
const LIGHT = rgb(0.9, 0.92, 0.94);

export type SourceFile = { item: BrokerPacketItemRow; bytes: Uint8Array };
export type GeneratedBrokerPacket = {
  bytes: Uint8Array;
  pageCount: number;
  itemResults: { item_id: string; source_content_hash: string; start_page: number; end_page: number }[];
};

type BrokerPacketPdfInput = {
  version: number;
  generatedAt: Date;
  organization: OrganizationSnapshot;
  broker: BrokerSnapshot;
  carrier: CarrierSnapshot | null;
  sources: SourceFile[];
};

type PreparedSource = SourceFile & { pageCount: number; sourcePdf?: PDFDocument };

// Renderer input boundary (2M.3 section 2): this function consumes ONLY
// the frozen organization/broker/carrier snapshots and the packet items
// already fetched by the caller -- it never queries organizations,
// brokers, or carriers itself, so it structurally cannot rebuild identity
// from live tables after reservation.
export async function renderBrokerPacket(input: BrokerPacketPdfInput): Promise<GeneratedBrokerPacket> {
  if (input.sources.length === 0) throw new Error("Select at least one source document.");
  const prepared: PreparedSource[] = [];
  for (const source of [...input.sources].sort((a, b) => a.item.display_order - b.item.display_order)) {
    const mime = source.item.source_mime_type;
    if (mime === "application/pdf") {
      let sourcePdf: PDFDocument;
      try {
        sourcePdf = await PDFDocument.load(source.bytes, { ignoreEncryption: true });
      } catch {
        throw new Error(`${source.item.source_filename} is not a readable PDF.`);
      }
      let pageCount: number;
      try {
        pageCount = sourcePdf.getPageCount();
      } catch {
        throw new Error(`${source.item.source_filename} has an invalid PDF page structure.`);
      }
      if (pageCount < 1) throw new Error(`${source.item.source_filename} has no pages.`);
      prepared.push({ ...source, pageCount, sourcePdf });
    } else if (mime === "image/jpeg" || mime === "image/png") {
      // 0095 eligibility already restricts sources to PDF/JPEG/PNG (see
      // guard_broker_packet_item()) -- no broader scope introduced here.
      prepared.push({ ...source, pageCount: 1 });
    } else {
      throw new Error(`${source.item.source_filename} has an unsupported file type.`);
    }
  }

  const pageCount = 1 + prepared.reduce((sum, source) => sum + source.pageCount, 0);
  if (pageCount > MAX_PACKAGE_PAGES) throw new Error(`This packet would contain ${pageCount} pages; the maximum is ${MAX_PACKAGE_PAGES}.`);

  // Page-range calculation (section 7): cover is page 1, sources follow in
  // exact packet item order starting at page 2.
  const ranges = new Map<string, { start: number; end: number }>();
  let cursor = 2;
  for (const source of prepared) {
    ranges.set(source.item.id, { start: cursor, end: cursor + source.pageCount - 1 });
    cursor += source.pageCount;
  }

  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  drawCover(pdf.addPage([LETTER_WIDTH, LETTER_HEIGHT]), input, prepared, ranges, regular, bold);

  for (const source of prepared) {
    if (source.sourcePdf) {
      try {
        const pages = await pdf.copyPages(source.sourcePdf, source.sourcePdf.getPageIndices());
        for (const page of pages) pdf.addPage(page);
      } catch {
        throw new Error(`${source.item.source_filename} could not be merged because its PDF structure is unsupported.`);
      }
      continue;
    }
    const page = pdf.addPage([LETTER_WIDTH, LETTER_HEIGHT]);
    try {
      const image = source.item.source_mime_type === "image/png" ? await pdf.embedPng(source.bytes) : await pdf.embedJpg(source.bytes);
      const maxWidth = LETTER_WIDTH - MARGIN * 2;
      const maxHeight = LETTER_HEIGHT - MARGIN * 2;
      const scale = Math.min(maxWidth / image.width, maxHeight / image.height, 1);
      const width = image.width * scale;
      const height = image.height * scale;
      page.drawImage(image, { x: (LETTER_WIDTH - width) / 2, y: (LETTER_HEIGHT - height) / 2, width, height });
    } catch {
      throw new Error(`${source.item.source_filename} is not a readable ${source.item.source_mime_type === "image/png" ? "PNG" : "JPEG"} image.`);
    }
  }

  // Final byte generation (section 8): hash/size/page-count are all
  // derived from these exact saved bytes, after every mutation, never
  // before and never re-derived from anything else.
  const bytes = await pdf.save({ useObjectStreams: true });
  if (bytes.length > MAX_GENERATED_BYTES) throw new Error("The generated PDF exceeds the 50 MB broker packet limit.");
  return {
    bytes,
    pageCount,
    itemResults: prepared.map((source) => ({
      item_id: source.item.id,
      source_content_hash: createHash("sha256").update(source.bytes).digest("hex"),
      start_page: ranges.get(source.item.id)!.start,
      end_page: ranges.get(source.item.id)!.end,
    })),
  };
}

function drawCover(page: PDFPage, input: BrokerPacketPdfInput, sources: PreparedSource[], ranges: Map<string, { start: number; end: number }>, regular: PDFFont, bold: PDFFont) {
  page.drawRectangle({ x: 0, y: LETTER_HEIGHT - 10, width: LETTER_WIDTH, height: 10, color: NAVY });
  page.drawText(truncateToWidth(input.organization.name || "Dispatch Company", regular, 11, LETTER_WIDTH - MARGIN * 2), { x: MARGIN, y: 724, size: 11, font: bold, color: NAVY });
  page.drawText("BROKER PACKET", { x: MARGIN, y: 660, size: 25, font: bold, color: NAVY });
  page.drawRectangle({ x: MARGIN, y: 641, width: 70, height: 3, color: NAVY });

  let y = 603;
  y = wrapped(page, input.broker.legal_name || "Broker", MARGIN, y, bold, 17, LETTER_WIDTH - MARGIN * 2, 20, NAVY);
  if (input.broker.dba_name) y = wrapped(page, `DBA ${input.broker.dba_name}`, MARGIN, y - 1, regular, 10, LETTER_WIDTH - MARGIN * 2, 13, SLATE);
  const brokerIds = [input.broker.mc_number ? `MC # ${input.broker.mc_number}` : null, input.broker.dot_number ? `USDOT # ${input.broker.dot_number}` : null].filter(Boolean).join("    ");
  if (brokerIds) {
    page.drawText(brokerIds, { x: MARGIN, y: y - 4, size: 9.5, font: bold, color: NAVY });
    y -= 4;
  }
  y -= 14;

  // Fixed-anchor sections below the (variable-height) broker header, each
  // clamped to a bounded number of lines, so a long name / many optional
  // fields / up to MAX_PACKET_DOCUMENTS (12) items can never collide with
  // the footer -- verified visually against every combination in 2M.3
  // section 20 (long names, missing optional fields, up to 12 documents).
  const carrierTop = Math.min(y, 470);
  let nextTop = carrierTop;
  if (input.carrier) {
    sectionLabel(page, "CARRIER", carrierTop, bold);
    let cy = carrierTop - 22;
    cy = wrapped(page, input.carrier.legal_name || "Carrier", MARGIN, cy, bold, 11.5, LETTER_WIDTH - MARGIN * 2, 15, NAVY);
    const carrierLine2 = [input.carrier.dba_name ? `DBA ${input.carrier.dba_name}` : null, input.carrier.mc_number ? `MC # ${input.carrier.mc_number}` : null, input.carrier.dot_number ? `USDOT # ${input.carrier.dot_number}` : null]
      .filter(Boolean)
      .join("    ");
    if (carrierLine2) {
      cy = wrapped(page, carrierLine2, MARGIN, cy, regular, 9.5, LETTER_WIDTH - MARGIN * 2, 13, SLATE);
    }
    const contactLine = [input.carrier.contact_name, input.carrier.phone, input.carrier.email].filter(Boolean).join("   |   ");
    if (contactLine) cy = wrapped(page, contactLine, MARGIN, cy, regular, 9.5, LETTER_WIDTH - MARGIN * 2, 13, SLATE);
    nextTop = cy - 16;
  }

  const documentsTop = Math.min(nextTop, 400);
  sectionLabel(page, "INCLUDED DOCUMENTS", documentsTop, bold);
  let dy = documentsTop - 24;
  const rowHeight = sources.length > 8 ? 17 : 22;
  sources.forEach((source, index) => {
    const range = ranges.get(source.item.id)!;
    const pages = range.start === range.end ? String(range.start) : `${range.start}-${range.end}`;
    page.drawText(String(index + 1).padStart(2, "0"), { x: MARGIN, y: dy, size: 9, font: bold, color: SLATE });
    const label = truncateToWidth(DOCUMENT_LABELS[source.item.document_type] ?? source.item.document_type.replaceAll("_", " "), regular, 10.5, LETTER_WIDTH - MARGIN * 2 - 90);
    page.drawText(label, { x: MARGIN + 24, y: dy, size: 10.5, font: regular, color: NAVY });
    const width = regular.widthOfTextAtSize(pages, 9.5);
    page.drawText(pages, { x: LETTER_WIDTH - MARGIN - width, y: dy, size: 9.5, font: regular, color: SLATE });
    page.drawLine({ start: { x: MARGIN + 24, y: dy - 7 }, end: { x: LETTER_WIDTH - MARGIN, y: dy - 7 }, thickness: 0.5, color: LIGHT });
    dy -= rowHeight;
  });

  page.drawLine({ start: { x: MARGIN, y: 90 }, end: { x: LETTER_WIDTH - MARGIN, y: 90 }, thickness: 1, color: LIGHT });
  smallPair(page, "Generated", formatDate(input.generatedAt), MARGIN, 62, regular, bold);
  smallPair(page, "Prepared By", truncateToWidth(input.organization.name || "Dispatch Company", bold, 9, 160), 250, 62, regular, bold);
  smallPair(page, "Packet", `v${input.version}`, 470, 62, regular, bold);
  page.drawText("Broker Packet", { x: MARGIN, y: 25, size: 7.5, font: regular, color: SLATE });
}

function wrapped(page: PDFPage, text: string, x: number, y: number, font: PDFFont, size: number, maxWidth: number, lineHeight: number, color = NAVY) {
  let line = "";
  for (const word of text.replace(/[\r\n]+/g, " ").split(/\s+/)) {
    const next = line ? `${line} ${word}` : word;
    if (line && font.widthOfTextAtSize(next, size) > maxWidth) {
      page.drawText(line, { x, y, size, font, color });
      y -= lineHeight;
      line = word;
    } else line = next;
  }
  if (line) {
    page.drawText(line, { x, y, size, font, color });
    y -= lineHeight;
  }
  return y;
}

function truncateToWidth(text: string, font: PDFFont, size: number, maxWidth: number) {
  if (font.widthOfTextAtSize(text, size) <= maxWidth) return text;
  let truncated = text;
  while (truncated.length > 1 && font.widthOfTextAtSize(`${truncated}…`, size) > maxWidth) truncated = truncated.slice(0, -1);
  return `${truncated}…`;
}

function sectionLabel(page: PDFPage, text: string, y: number, bold: PDFFont) {
  page.drawText(text, { x: MARGIN, y, size: 8.5, font: bold, color: SLATE });
  page.drawLine({ start: { x: MARGIN, y: y - 8 }, end: { x: LETTER_WIDTH - MARGIN, y: y - 8 }, thickness: 0.7, color: LIGHT });
}
function smallPair(page: PDFPage, label: string, value: string, x: number, y: number, regular: PDFFont, bold: PDFFont) {
  page.drawText(label, { x, y, size: 7.5, font: regular, color: SLATE });
  page.drawText(value, { x, y: y - 16, size: 9, font: bold, color: NAVY });
}
function formatDate(date: Date) {
  return new Intl.DateTimeFormat("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" }).format(date);
}
